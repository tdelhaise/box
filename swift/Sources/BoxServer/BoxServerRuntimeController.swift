import BoxCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(SystemConfiguration)
import SystemConfiguration
#endif
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

#if os(Linux)
import Glibc
#elseif os(Windows)
import WinSDK
#else
import Darwin
#endif

final class BoxServerRuntimeController: @unchecked Sendable {
    private var options: BoxRuntimeOptions
    private var logger: Logger
    private let eventLoopGroup: EventLoopGroup
    internal let state: NIOLockedValueBox<BoxServerRuntimeState>
    private var mainChannel: Channel?
    private var adminChannel: BoxAdminChannelHandle?
    private var locationCoordinator: LocationServiceCoordinator?
    private var portMappingCoordinator: PortMappingCoordinator?
    private var store: BoxServerStore?
    private var noiseKeyStore: BoxNoiseKeyStore?
    private var presenceTask: Task<Void, Never>?
    private static let locationSummaryGraceInterval: TimeInterval = 120

    init(options: BoxRuntimeOptions) {
        self.options = options
        self.logger = Logger(label: "box.server")
        self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

        let initialConnectivity = Self.probeConnectivity(logger: self.logger)
        let initialState = BoxServerRuntimeState(
            configurationPath: options.configurationPath,
            configuration: nil,
            logLevel: options.logLevel,
            logLevelOrigin: options.logLevelOrigin,
            logTarget: options.logTarget,
            logTargetOrigin: options.logTargetOrigin,
            adminChannelEnabled: options.adminChannelEnabled,
            port: options.port,
            portOrigin: options.portOrigin,
            transport: nil, // This will be set from config
            nodeIdentifier: options.nodeId,
            userIdentifier: options.userId,
            queueRootPath: nil,
            reloadCount: 0,
            lastReloadTimestamp: nil,
            lastReloadStatus: "never",
            lastReloadError: nil,
            hasGlobalIPv6: initialConnectivity.hasGlobalIPv6,
            globalIPv6Addresses: initialConnectivity.globalIPv6Addresses,
            ipv6DetectionError: initialConnectivity.detectionErrorDescription,
            portMappingRequested: options.portMappingRequested,
            portMappingOrigin: options.portMappingOrigin,
            manualExternalAddress: options.externalAddressOverride,
            manualExternalPort: options.externalPortOverride,
            manualExternalOrigin: options.externalAddressOrigin,
            onlineSince: Date(),
            lastPresenceUpdate: nil,
            permanentQueues: options.permanentQueues,
            nodeIdentityPublicKey: nil
        )
        self.state = NIOLockedValueBox(initialState)
    }

    func start() async throws {
        setupLogging()
        try enforceNonRoot(logger: logger)

        let home = try resolveHomeDirectory()
        try ensureBoxDirectories(home: home, logger: logger)

        let queueRoot = try ensureQueueInfrastructure(logger: logger)
        state.withLockedValue { $0.queueRootPath = queueRoot.path }

        let store = try await BoxServerStore(root: queueRoot, logger: self.logger)
        self.store = store

        let locationCoordinator = LocationServiceCoordinator(store: store, logger: self.logger)
        try await locationCoordinator.bootstrap()
        self.locationCoordinator = locationCoordinator

        await initializeNodeIdentity()

        try await reloadConfiguration(path: options.configurationPath, initial: true)

        let bootstrap = DatagramBootstrap(group: eventLoopGroup)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                let handler = BoxServerHandler(
                    logger: self.logger,
                    allocator: channel.allocator,
                    store: store,
                    identityProvider: { [weak self] in
                        guard let self else { return (UUID(), UUID()) }
                        return self.state.withLockedValue { ($0.nodeIdentifier, $0.userIdentifier) }
                    },
                    authorizer: { [weak self] nodeId, userId in
                        guard let self, let coordinator = self.locationCoordinator else { return false }
                        return await coordinator.authorize(nodeUUID: nodeId, userUUID: userId)
                    },
                    locationResolver: { [weak self] nodeId in
                        guard let self, let coordinator = self.locationCoordinator else { return nil }
                        return await coordinator.resolve(nodeUUID: nodeId)
                    },
                    isPermanentQueue: { [weak self] rawQueue in
                        guard let self else { return false }
                        guard let normalized = try? BoxServerStore.normalizeQueueName(rawQueue) else { return false }
                        return self.state.withLockedValue { $0.permanentQueues.contains(normalized) }
                    }
                )
                return channel.pipeline.addHandler(handler)
            }

        let port = state.withLockedValue { $0.port }
        mainChannel = try await bootstrap.bind(host: "::", port: Int(port)).get()
        logger.info("server bound", metadata: ["host": "::", "port": "\(port)"])

        if state.withLockedValue({ $0.adminChannelEnabled }) {
            try await startAdminChannel()
        }

        startPortMappingCoordinator()
        startPresenceTask()

        logStartupSummary()

        try await mainChannel?.closeFuture.get()
        logger.info("server channel closed")
    }

    func stop() async {
        logger.info("server shutdown requested")
        presenceTask?.cancel()
        portMappingCoordinator?.stop()

        if let admin = adminChannel {
            initiateAdminChannelShutdown(admin)
            await waitForAdminChannelShutdown(admin)
            self.adminChannel = nil
        }

        mainChannel?.close(promise: nil)
        try? await mainChannel?.closeFuture.get()
        mainChannel = nil

        try? await eventLoopGroup.shutdownGracefully()
        logger.info("server stopped")
    }

    private func setupLogging() {
        let (level, target) = state.withLockedValue { ($0.logLevel, $0.logTarget) }
        BoxLogging.bootstrap(level: level, target: target)
        logger.debug("logging configured", metadata: ["level": "\(level)", "target": "\(logTargetDescription(target))"])
    }

    private func resolveHomeDirectory() throws -> URL {
        guard let home = BoxPaths.homeDirectory() else {
            throw BoxRuntimeError.storageUnavailable("Home directory could not be resolved")
        }
        return home
    }

    private func startAdminChannel() async throws {
        guard let socketPath = BoxPaths.adminSocketPath() else {
            logger.warning("admin channel disabled: could not resolve socket path")
            return
        }
        adminChannel = try await startAdminChannel(
            on: eventLoopGroup,
            socketPath: socketPath,
            logger: logger,
            statusProvider: { [weak self] in
                guard let self else { return "{\"status\":\"error\",\"message\":\"shutting-down\"}" }
                return await self.renderStatus()
            },
            logTargetUpdater: { [weak self] targetDescription in
                await self?.updateLogTarget(from: targetDescription) ?? "{\"status\":\"error\",\"message\":\"shutting-down\"}"
            },
            reloadConfiguration: { [weak self] path in
                await self?.handleReload(path: path) ?? "{\"status\":\"error\",\"message\":\"shutting-down\"}"
            },
            statsProvider: { [weak self] in
                guard let self else { return "{\"status\":\"error\",\"message\":\"shutting-down\"}" }
                return await self.renderStats()
            },
            locateNode: { [weak self] uuid in
                guard let self, let coordinator = self.locationCoordinator else {
                    return adminResponse(["status": "error", "message": "location-service-unavailable"])
                }
                if let record = await coordinator.resolve(nodeUUID: uuid) {
                    return adminResponse(adminLocationRecordPayload(from: record))
                }
                let records = await coordinator.resolve(userUUID: uuid)
                if !records.isEmpty {
                    return adminResponse(adminLocationUserPayload(userUUID: uuid, records: records))
                }
                return adminResponse(["status": "error", "message": "node-not-found"])
            },
            natProbe: { [weak self] gateway in
                await self?.handleNatProbe(gateway: gateway) ?? "{\"status\":\"error\",\"message\":\"shutting-down\"}"
            },
            locationSummaryProvider: { [weak self] in
                await self?.renderLocationSummary() ?? "{\"status\":\"error\",\"message\":\"shutting-down\"}"
            }
        )
        logger.info("admin channel bound", metadata: ["path": .string(socketPath)])
    }

    private func startPresenceTask() {
        presenceTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                await self?.publishPresence()
                do {
                    try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                } catch {
                    break
                }
            }
        }
    }

    private func initializeNodeIdentity() async {
        do {
            let keyStore = try BoxNoiseKeyStore()
            noiseKeyStore = keyStore
            let identity = try await keyStore.ensureIdentity(for: .node)
            let publicKeyHex = hexString(from: identity.publicKey)
            state.withLockedValue { runtime in
                runtime.nodeIdentityPublicKey = "hex:\(publicKeyHex)"
            }
        } catch {
            logger.warning("failed to initialize node identity", metadata: ["error": .string("\(error)")])
        }
    }

    private func publishPresence() async {
        guard let coordinator = locationCoordinator, let record = buildLocationServiceRecord() else { return }
        await coordinator.publish(record: record)
        state.withLockedValue {
            $0.lastPresenceUpdate = Date()
        }
    }

    private func startPortMappingCoordinator() {
        let (requested, origin, port, nodeIdentifier, userIdentifier) = state.withLockedValue {
            (
                $0.portMappingRequested,
                $0.portMappingOrigin,
                $0.port,
                $0.nodeIdentifier,
                $0.userIdentifier
            )
        }
        guard requested else {
            logger.debug("port mapping disabled by configuration")
            return
        }
        portMappingCoordinator = PortMappingCoordinator(
            logger: logger,
            port: port,
            origin: origin,
            nodeIdentifier: nodeIdentifier,
            userIdentifier: userIdentifier,
            onStateChange: { [weak self] snapshot in
                self?.updatePortMappingState(snapshot)
            }
        )
        portMappingCoordinator?.start()
    }

    private func updatePortMappingState(_ snapshot: PortMappingCoordinator.MappingSnapshot?) {
        state.withLockedValue {
            $0.portMappingBackend = snapshot?.backend
            $0.portMappingExternalPort = snapshot?.externalPort
            $0.portMappingGateway = snapshot?.gateway
            $0.portMappingService = snapshot?.service
            $0.portMappingLeaseSeconds = snapshot?.lifetime
            $0.portMappingLastRefresh = snapshot?.refreshedAt
            $0.portMappingExternalIPv4 = snapshot?.externalIPv4
            $0.portMappingPeerStatus = snapshot?.peerStatus
            $0.portMappingPeerLifetime = snapshot?.peerLifetime
            $0.portMappingPeerLastUpdate = snapshot?.peerLastUpdate
            $0.portMappingPeerError = snapshot?.peerError
            $0.portMappingStatus = snapshot?.status
            $0.portMappingError = snapshot?.error
            $0.portMappingErrorCode = snapshot?.errorCode
            $0.portMappingReachabilityStatus = snapshot?.reachabilityStatus
            $0.portMappingReachabilityCheckedAt = snapshot?.reachabilityCheckedAt
            $0.portMappingReachabilityRoundTripMillis = snapshot?.reachabilityRoundTripMillis
            $0.portMappingReachabilityError = snapshot?.reachabilityError
        }
        Task { [weak self] in
            await self?.publishPresence()
        }
    }

    private func updateLogTarget(from description: String) async -> String {
        guard let target = BoxLogTarget.parse(description) else {
            return "{\"status\":\"error\",\"message\":\"invalid-log-target\"}"
        }
        state.withLockedValue {
            $0.logTarget = target
            $0.logTargetOrigin = .runtime
        }
        BoxLogging.update(target: target)
        logger.info("log target updated", metadata: ["target": "\(logTargetDescription(target))", "origin": "admin"])
        let snapshot = state.withLockedValue { $0 }
        let response: [String: Any] = [
            "status": "ok",
            "logTarget": logTargetDescription(snapshot.logTarget),
            "logTargetOrigin": "\(snapshot.logTargetOrigin)"
        ]
        return adminResponse(response)
    }

    private func handleReload(path: String?) async -> String {
        let effectivePath = path ?? state.withLockedValue { $0.configurationPath }
        do {
            try await reloadConfiguration(path: effectivePath, initial: false)
            let snapshot = state.withLockedValue { $0 }
            let metrics = store.map { Self.queueMetrics(at: $0.root) } ?? QueueMetrics.zero
            var result = statusDictionary(from: snapshot, metrics: metrics)
            result["status"] = "ok"
            result["path"] = effectivePath ?? "none"
            if let record = buildLocationServiceRecord() {
                result["addresses"] = adminAddressesPayload(from: record)
                result["connectivity"] = adminConnectivityPayload(from: record)
            }
            if let summary = await locationServiceSummaryPayload() {
                result["locationService"] = summary
            }
            return adminResponse(result)
        } catch {
            let result: [String: Any] = [
                "status": "error",
                "path": effectivePath ?? "none",
                "message": "\(error)"
            ]
            return adminResponse(result)
        }
    }

    private func handleNatProbe(gateway: String?) async -> String {
        if let skip = getenv("BOX_SKIP_NAT_PROBE"), skip[0] != 0 {
            return adminResponse(["status": "skipped", "reports": []])
        }
        guard let coordinator = portMappingCoordinator else {
            return adminResponse(["status": "disabled", "reports": []])
        }
        let reports = await coordinator.probe(gatewayOverride: gateway)
        let payload: [String: Any] = [
            "status": "ok",
            "reports": reports.map { $0.toDictionary() }
        ]
        return adminResponse(payload)
    }

    private func statusDictionary(from snapshot: BoxServerRuntimeState, metrics: QueueMetrics) -> [String: Any] {
        [
            "nodeUUID": snapshot.nodeIdentifier.uuidString,
            "userUUID": snapshot.userIdentifier.uuidString,
            "logLevel": "\(snapshot.logLevel)",
            "logLevelOrigin": "\(snapshot.logLevelOrigin)",
            "logTarget": logTargetDescription(snapshot.logTarget),
            "logTargetOrigin": "\(snapshot.logTargetOrigin)",
            "port": snapshot.port,
            "portOrigin": "\(snapshot.portOrigin)",
            "hasGlobalIPv6": snapshot.hasGlobalIPv6,
            "globalIPv6Addresses": snapshot.globalIPv6Addresses,
            "ipv6ProbeError": snapshot.ipv6DetectionError ?? NSNull(),
            "nodePublicKey": snapshot.nodeIdentityPublicKey ?? NSNull(),
            "portMappingEnabled": snapshot.portMappingRequested,
            "portMappingOrigin": "\(snapshot.portMappingOrigin)",
            "portMappingBackend": snapshot.portMappingBackend ?? NSNull(),
            "portMappingExternalPort": snapshot.portMappingExternalPort ?? NSNull(),
            "portMappingExternalIPv4": snapshot.portMappingExternalIPv4 ?? NSNull(),
            "portMappingLeaseSeconds": snapshot.portMappingLeaseSeconds ?? NSNull(),
            "portMappingRefreshedAt": snapshot.portMappingLastRefresh.map { iso8601String($0) } ?? NSNull(),
            "portMappingPeerStatus": snapshot.portMappingPeerStatus ?? NSNull(),
            "portMappingPeerLifetime": snapshot.portMappingPeerLifetime ?? NSNull(),
            "portMappingPeerLastUpdated": snapshot.portMappingPeerLastUpdate.map { iso8601String($0) } ?? NSNull(),
            "portMappingPeerError": snapshot.portMappingPeerError ?? NSNull(),
            "portMappingStatus": snapshot.portMappingStatus ?? NSNull(),
            "portMappingError": snapshot.portMappingError ?? NSNull(),
            "portMappingErrorCode": snapshot.portMappingErrorCode ?? NSNull(),
            "portMappingReachabilityStatus": snapshot.portMappingReachabilityStatus ?? NSNull(),
            "portMappingReachabilityCheckedAt": snapshot.portMappingReachabilityCheckedAt.map { iso8601String($0) } ?? NSNull(),
            "portMappingReachabilityRoundTripMillis": snapshot.portMappingReachabilityRoundTripMillis ?? NSNull(),
            "portMappingReachabilityError": snapshot.portMappingReachabilityError ?? NSNull(),
            "queueRoot": snapshot.queueRootPath ?? NSNull(),
            "queueCount": metrics.count,
            "objects": metrics.objectCount,
            "queueFreeBytes": metrics.freeBytes ?? NSNull(),
            "permanentQueues": Array(snapshot.permanentQueues).sorted(),
            "reloadCount": snapshot.reloadCount,
            "lastReload": snapshot.lastReloadTimestamp.map { iso8601String($0) } ?? NSNull(),
            "lastReloadStatus": snapshot.lastReloadStatus,
            "lastReloadError": snapshot.lastReloadError ?? NSNull(),
            "onlineSince": iso8601String(snapshot.onlineSince),
            "lastPresenceUpdate": snapshot.lastPresenceUpdate.map { iso8601String($0) } ?? NSNull()
        ]
    }

    private func reloadConfiguration(path: String?, initial: Bool) async throws {
        guard let result = try BoxConfiguration.loadDefault(explicitPath: path) else {
            throw BoxRuntimeError.storageUnavailable("Could not resolve configuration path")
        }
        let config = result.configuration
        state.withLockedValue {
            $0.configuration = config
            $0.configurationPath = result.url.path
            $0.logLevel = config.effectiveLogLevel(options: options)
            $0.logLevelOrigin = config.logLevelOrigin(options: options)
            $0.logTarget = config.effectiveLogTarget(options: options)
            $0.logTargetOrigin = config.logTargetOrigin(options: options)
            $0.port = config.effectivePort(options: options)
            $0.portOrigin = config.portOrigin(options: options)
            $0.adminChannelEnabled = config.effectiveAdminChannelEnabled(options: options)
            $0.portMappingRequested = config.effectivePortMappingEnabled(options: options)
            $0.portMappingOrigin = config.portMappingOrigin(options: options)
            $0.manualExternalAddress = config.effectiveExternalAddress(options: options)
            $0.manualExternalPort = config.effectiveExternalPort(options: options)
            $0.manualExternalOrigin = config.externalAddressOrigin(options: options)
            $0.transport = config.server.transportGeneral
            let sanitizedQueues = Set((config.server.permanentQueues ?? []).compactMap { queue -> String? in
                try? BoxServerStore.normalizeQueueName(queue)
            })
            $0.permanentQueues = sanitizedQueues
            options.permanentQueues = sanitizedQueues

            if !initial {
                $0.reloadCount += 1
                $0.lastReloadTimestamp = Date()
                $0.lastReloadStatus = "ok"
                $0.lastReloadError = nil
            }
        }
        setupLogging()
        logger.info("configuration loaded", metadata: ["path": .string(result.url.path)])
    }

    private func logStartupSummary() {
        let snapshot = state.withLockedValue { $0 }
        var metadata: [String: Logger.MetadataValue] = [: ]
        metadata["port"] = "\(snapshot.port)"
        metadata["portOrigin"] = "\(snapshot.portOrigin)"
        metadata["logLevel"] = "\(snapshot.logLevel)"
        metadata["logLevelOrigin"] = "\(snapshot.logLevelOrigin)"
        metadata["logTarget"] = "\(logTargetDescription(snapshot.logTarget))"
        metadata["logTargetOrigin"] = "\(snapshot.logTargetOrigin)"
        metadata["configurationPresent"] = "\(snapshot.configurationPath != nil)"
        metadata["adminChannelEnabled"] = "\(snapshot.adminChannelEnabled)"
        metadata["transport"] = "\(snapshot.transport ?? "default")"
        metadata["portMappingRequested"] = "\(snapshot.portMappingRequested)"
        metadata["portMappingOrigin"] = "\(snapshot.portMappingOrigin)"
        metadata["manualExternalAddress"] = "\(snapshot.manualExternalAddress ?? "none")"
        metadata["manualExternalPort"] = "\(snapshot.manualExternalPort.map { String($0) } ?? "none")"
        metadata["manualExternalOrigin"] = "\(snapshot.manualExternalOrigin)"
        metadata["permanentQueues"] = "\(Array(snapshot.permanentQueues).sorted())"

        let connectivity = ConnectivitySnapshot(
            globalIPv6Addresses: snapshot.globalIPv6Addresses,
            detectionErrorDescription: snapshot.ipv6DetectionError
        )
        metadata["connectivity"] = "\(connectivity)"

        logger.info("server starting", metadata: metadata)
    }

    private func renderStatus() async -> String {
        let snapshot = state.withLockedValue { $0 }
        let metrics = store.map { Self.queueMetrics(at: $0.root) } ?? QueueMetrics.zero
        var payload = statusDictionary(from: snapshot, metrics: metrics)
        payload["status"] = "ok"
        if let record = buildLocationServiceRecord() {
            payload["addresses"] = adminAddressesPayload(from: record)
            payload["connectivity"] = adminConnectivityPayload(from: record)
        }
        if let summary = await locationServiceSummaryPayload() {
            payload["locationService"] = summary
        }
        return adminResponse(payload)
    }

    private func renderLocationSummary() async -> String {
        guard let summary = await locationServiceSummaryPayload() else {
            return adminResponse(["status": "error", "message": "location-service-unavailable"])
        }
        return adminResponse([
            "status": "ok",
            "summary": summary
        ])
    }

    private func renderStats() async -> String {
        let snapshot = state.withLockedValue { $0 }
        let metrics = store.map { Self.queueMetrics(at: $0.root) } ?? QueueMetrics.zero
        var payload: [String: Any] = [
            "logLevel": "\(snapshot.logLevel)",
            "logLevelOrigin": "\(snapshot.logLevelOrigin)",
            "logTarget": logTargetDescription(snapshot.logTarget),
            "logTargetOrigin": "\(snapshot.logTargetOrigin)",
            "queueCount": metrics.count,
            "objects": metrics.objectCount,
            "queueFreeBytes": metrics.freeBytes ?? NSNull(),
            "hasGlobalIPv6": snapshot.hasGlobalIPv6,
            "portMappingEnabled": snapshot.portMappingRequested
        ]
        if let record = buildLocationServiceRecord() {
            payload["addresses"] = adminAddressesPayload(from: record)
            payload["connectivity"] = adminConnectivityPayload(from: record)
        } else {
            payload["addresses"] = []
            payload["connectivity"] = NSNull()
        }
        if let summary = await locationServiceSummaryPayload() {
            payload["locationService"] = summary
        }
        return adminResponse(payload)
    }

    private func buildLocationServiceRecord() -> LocationServiceNodeRecord? {
        let snapshot = state.withLockedValue { $0 }
        let peer: LocationServiceNodeRecord.Connectivity.PortMapping.Peer? = {
            guard let status = snapshot.portMappingPeerStatus else { return nil }
            let lastUpdated = snapshot.portMappingPeerLastUpdate.map { UInt64($0.timeIntervalSince1970 * 1000) }
            return LocationServiceNodeRecord.Connectivity.PortMapping.Peer(
                status: status,
                lifetimeSeconds: snapshot.portMappingPeerLifetime,
                lastUpdated: lastUpdated,
                error: snapshot.portMappingPeerError
            )
        }()

        let reachability: LocationServiceNodeRecord.Connectivity.PortMapping.Reachability? = {
            guard let status = snapshot.portMappingReachabilityStatus else { return nil }
            let lastChecked = snapshot.portMappingReachabilityCheckedAt.map { UInt64($0.timeIntervalSince1970 * 1000) }
            let roundTrip = snapshot.portMappingReachabilityRoundTripMillis.flatMap { value -> UInt32? in
                value >= 0 ? UInt32(clamping: value) : nil
            }
            return LocationServiceNodeRecord.Connectivity.PortMapping.Reachability(
                status: status,
                lastChecked: lastChecked,
                roundTripMillis: roundTrip,
                error: snapshot.portMappingReachabilityError
            )
        }()

        return LocationServiceNodeRecord.make(
            userUUID: snapshot.userIdentifier,
            nodeUUID: snapshot.nodeIdentifier,
            port: snapshot.port,
            probedGlobalIPv6: snapshot.globalIPv6Addresses,
            ipv6Error: snapshot.ipv6DetectionError,
            portMappingEnabled: snapshot.portMappingRequested,
            portMappingOrigin: snapshot.portMappingOrigin,
            additionalAddresses: [],
            portMappingExternalIPv4: snapshot.portMappingExternalIPv4,
            portMappingExternalPort: snapshot.portMappingExternalPort,
            portMappingPeer: peer,
            portMappingStatus: snapshot.portMappingStatus,
            portMappingError: snapshot.portMappingError,
            portMappingErrorCode: snapshot.portMappingErrorCode,
            portMappingReachability: reachability,
            online: true,
            since: UInt64(snapshot.onlineSince.timeIntervalSince1970 * 1000),
            lastSeen: snapshot.lastPresenceUpdate.map { UInt64($0.timeIntervalSince1970 * 1000) },
            nodePublicKey: snapshot.nodeIdentityPublicKey,
            tags: nil
        )
    }
    
    private func enforceNonRoot(logger: Logger) throws {
        #if os(Linux) || os(macOS)
        if geteuid() == 0 {
            throw BoxRuntimeError.forbiddenOperation("boxd must not run as root")
        }
        #else
        logger.debug("non-root enforcement skipped on this platform")
        #endif
    }

    private func ensureBoxDirectories(home: URL, logger: Logger) throws {
        guard let boxDirectory = BoxPaths.boxDirectory(),
              let runDirectory = BoxPaths.runDirectory(),
              let logsDirectory = BoxPaths.logsDirectory() else {
            logger.warning("unable to resolve ~/.box directories")
            return
        }
        try createDirectoryIfNeeded(at: boxDirectory)
        try createDirectoryIfNeeded(at: runDirectory)
        try createDirectoryIfNeeded(at: logsDirectory)
    }

    private func createDirectoryIfNeeded(at url: URL) throws {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        #if !os(Windows)
        let attributes: [FileAttributeKey: Any]? = [.posixPermissions: NSNumber(value: Int(S_IRWXU))]
        #else
        let attributes: [FileAttributeKey: Any]? = nil
        #endif
        if !exists {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: attributes)
        }
        #if !os(Windows)
        chmod(url.path, S_IRWXU)
        #endif
    }

    private func ensureQueueInfrastructure(logger: Logger) throws -> URL {
        guard let queueRoot = BoxPaths.queuesDirectory() else {
            throw BoxRuntimeError.storageUnavailable("unable to resolve ~/.box/queues directory")
        }

        try createDirectoryIfNeeded(at: queueRoot)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: queueRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BoxRuntimeError.storageUnavailable("queue root path \(queueRoot.path) is not a directory")
        }

        let inboxDirectory = queueRoot.appendingPathComponent("INBOX", isDirectory: true)
        try createDirectoryIfNeeded(at: inboxDirectory)
        guard FileManager.default.fileExists(atPath: inboxDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BoxRuntimeError.storageUnavailable("failed to create mandatory INBOX queue at \(inboxDirectory.path)")
        }

        return queueRoot
    }

    private static func queueMetrics(at root: URL) -> QueueMetrics {
        let fileManager = FileManager.default
        var queueCount = 0
        var objectCount = 0

        if let contents = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for url in contents {
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                    continue
                }
                queueCount += 1
                if let entries = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    objectCount += entries.reduce(0) { partial, fileURL in
                        fileURL.pathExtension.lowercased() == "json" ? partial + 1 : partial
                    }
                }
            }
        }

        var freeBytes: UInt64? = nil
        if let attributes = try? fileManager.attributesOfFileSystem(forPath: root.path),
           let freeSize = attributes[.systemFreeSize] as? NSNumber {
            freeBytes = freeSize.uint64Value
        }

        if queueCount < 1 {
            queueCount = 1
        }
        return QueueMetrics(count: queueCount, objectCount: objectCount, freeBytes: freeBytes)
    }

    private static func probeConnectivity(logger: Logger) -> ConnectivitySnapshot {
        #if os(Windows)
        return ConnectivitySnapshot(globalIPv6Addresses: [], detectionErrorDescription: "connectivity-probe-not-supported")
        #else
        var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPointer) == 0, let basePointer = ifaddrPointer else {
            let message = String(cString: strerror(errno))
            return ConnectivitySnapshot(globalIPv6Addresses: [], detectionErrorDescription: message)
        }
        defer { freeifaddrs(basePointer) }

        var addresses = Set<String>()
        var cursor = basePointer

        while true {
            let rawFlags = UInt32(cursor.pointee.ifa_flags)
            let flags = Int32(bitPattern: rawFlags)
            guard (flags & Int32(IFF_UP)) != 0 else {
                if let next = cursor.pointee.ifa_next { cursor = next; continue } else { break }
            }
            guard (flags & Int32(IFF_LOOPBACK)) == 0 else {
                if let next = cursor.pointee.ifa_next { cursor = next; continue } else { break }
            }
            guard let addr = cursor.pointee.ifa_addr else {
                if let next = cursor.pointee.ifa_next { cursor = next; continue } else { break }
            }

            if Int32(addr.pointee.sa_family) == AF_INET6 {
                let addressPointer = UnsafePointer<sockaddr>(addr)
                let ipv6Address = addressPointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                if Self.isGlobalUnicastIPv6(ipv6Address), let host = numericHostString(for: addressPointer) {
                    addresses.insert(host)
                }
            }

            if let next = cursor.pointee.ifa_next {
                cursor = next
            } else {
                break
            }
        }

        return ConnectivitySnapshot(globalIPv6Addresses: Array(addresses).sorted(), detectionErrorDescription: nil)
        #endif
    }

    private func adminAddressesPayload(from record: LocationServiceNodeRecord) -> [[String: Any]] {
        record.addresses.map { address in
            [
                "ip": address.ip,
                "port": Int(address.port),
                "scope": address.scope.rawValue,
                "source": address.source.rawValue
            ]
        }
    }

    private func locationServiceSummaryPayload() async -> [String: Any]? {
        guard let coordinator = locationCoordinator else { return nil }
        let summary = await coordinator.summary(staleAfter: Self.locationSummaryGraceInterval)
        var metadata: [String: Logger.MetadataValue] = [
            "totalNodes": .stringConvertible(summary.totalNodes),
            "activeNodes": .stringConvertible(summary.activeNodes),
            "totalUsers": .stringConvertible(summary.totalUsers),
            "threshold": .stringConvertible(summary.staleThresholdSeconds)
        ]
        if !summary.staleNodes.isEmpty {
            metadata["staleNodes"] = .array(summary.staleNodes.map { .string($0.uuidString) })
        }
        if !summary.staleUsers.isEmpty {
            metadata["staleUsers"] = .array(summary.staleUsers.map { .string($0.uuidString) })
        }

        if summary.staleNodes.isEmpty && summary.staleUsers.isEmpty {
            logger.debug("location service summary", metadata: metadata)
        } else {
            logger.warning("location service reports stale entries", metadata: metadata)
        }

        return adminLocationSummaryPayload(from: summary)
    }

    private func hexString(from bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func adminConnectivityPayload(from record: LocationServiceNodeRecord) -> [String: Any] {
        var portMappingPayload: [String: Any] = [
            "enabled": record.connectivity.portMapping.enabled,
            "origin": record.connectivity.portMapping.origin
        ]
        if let externalIPv4 = record.connectivity.portMapping.externalIPv4 {
            portMappingPayload["externalIPv4"] = externalIPv4
        }
        if let externalPort = record.connectivity.portMapping.externalPort {
            portMappingPayload["externalPort"] = Int(externalPort)
        }
        if let peer = record.connectivity.portMapping.peer {
            var peerPayload: [String: Any] = [
                "status": peer.status
            ]
            if let lifetime = peer.lifetimeSeconds {
                peerPayload["lifetimeSeconds"] = lifetime
            }
            if let lastUpdated = peer.lastUpdated {
                peerPayload["lastUpdated"] = lastUpdated
            }
            if let error = peer.error {
                peerPayload["error"] = error
            }
            portMappingPayload["peer"] = peerPayload
        }
        if let status = record.connectivity.portMapping.status {
            portMappingPayload["status"] = status
        }
        if let error = record.connectivity.portMapping.error {
            portMappingPayload["error"] = error
        }
        if let errorCode = record.connectivity.portMapping.errorCode {
            portMappingPayload["errorCode"] = errorCode
        }
        if let reachability = record.connectivity.portMapping.reachability {
            var reachabilityPayload: [String: Any] = [
                "status": reachability.status
            ]
            if let lastChecked = reachability.lastChecked {
                reachabilityPayload["lastChecked"] = lastChecked
            }
            if let roundTrip = reachability.roundTripMillis {
                reachabilityPayload["roundTripMillis"] = roundTrip
            }
            if let error = reachability.error {
                reachabilityPayload["error"] = error
            }
            portMappingPayload["reachability"] = reachabilityPayload
        }
        var payload: [String: Any] = [
            "hasGlobalIPv6": record.connectivity.hasGlobalIPv6,
            "globalIPv6": record.connectivity.globalIPv6,
            "portMapping": portMappingPayload
        ]
        if let error = record.connectivity.ipv6ProbeError {
            payload["ipv6ProbeError"] = error
        }
        return payload
    }

    #if !os(Windows)
    private static func isGlobalUnicastIPv6(_ address: in6_addr) -> Bool {
        return withUnsafeBytes(of: address) { rawBuffer -> Bool in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            guard bytes.count == 16 else { return false }

            var allZero = true
            for byte in bytes {
                if byte != 0 {
                    allZero = false
                    break
                }
            }
            if allZero { return false }

            var isLoopback = true
            for index in 0..<15 {
                if bytes[index] != 0 {
                    isLoopback = false
                    break
                }
            }
            if isLoopback && bytes[15] == 1 { return false }

            if bytes[0] == 0xff { return false }
            if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80 { return false }
            if (bytes[0] & 0xfe) == 0xfc { return false }

            return true
        }
    }
    #endif

    private func logTargetDescription(_ target: BoxLogTarget) -> String {
        switch target {
        case .stderr:
            return "stderr"
        case .stdout:
            return "stdout"
        case .file(let path):
            return "file:\(path)"
        }
    }

    private func initiateAdminChannelShutdown(_ handle: BoxAdminChannelHandle) {
        switch handle {
        case .nio(let channel):
            channel.close(promise: nil)
        #if os(Windows)
        case .pipe(let server):
            server.requestStop()
        #endif
        }
    }

    private func waitForAdminChannelShutdown(_ handle: BoxAdminChannelHandle) async {
        switch handle {
        case .nio(let channel):
            try? await channel.closeFuture.get()
        #if os(Windows)
        case .pipe(let server):
            await server.waitUntilStopped()
        #endif
        }
    }

    private func startAdminChannel(
        on eventLoopGroup: EventLoopGroup,
        socketPath: String,
        logger: Logger,
        statusProvider: @escaping @Sendable () async -> String,
        logTargetUpdater: @escaping @Sendable (String) async -> String,
        reloadConfiguration: @escaping @Sendable (String?) async -> String,
        statsProvider: @escaping @Sendable () async -> String,
        locateNode: @escaping @Sendable (UUID) async -> String,
        natProbe: @escaping @Sendable (String?) async -> String,
        locationSummaryProvider: @escaping @Sendable () async -> String
    ) async throws -> BoxAdminChannelHandle {
        let dispatcher = BoxAdminCommandDispatcher(
            statusProvider: statusProvider,
            logTargetUpdater: logTargetUpdater,
            reloadConfiguration: reloadConfiguration,
            statsProvider: statsProvider,
            locateNode: locateNode,
            natProbe: natProbe,
            locationSummaryProvider: locationSummaryProvider
        )

        #if os(Windows)
        let server = BoxAdminNamedPipeServer(path: socketPath, logger: logger, dispatcher: dispatcher)
        server.start()
        return .pipe(server)
        #else
        if FileManager.default.fileExists(atPath: socketPath) {
            do {
                try FileManager.default.removeItem(atPath: socketPath)
            } catch {
                let nsError = error as NSError
                let isCocoaMissing = nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileNoSuchFileError
                let isPosixMissing = nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT)
                if !(isCocoaMissing || isPosixMissing) {
                    throw error
                }
            }
        }

        let bootstrap = ServerBootstrap(group: eventLoopGroup)
            .serverChannelOption(ChannelOptions.backlog, value: 4)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(BoxAdminChannelHandler(logger: logger, dispatcher: dispatcher))
            }

        let channel = try await bootstrap.bind(unixDomainSocketPath: socketPath).get()
        chmod(socketPath, S_IRUSR | S_IWUSR)
        return .nio(channel)
        #endif
    }
}

extension BoxConfiguration {
    func effectiveLogLevel(options: BoxRuntimeOptions) -> Logger.Level {
        switch options.logLevelOrigin {
        case .cliFlag:
            return options.logLevel
        default:
            return server.logLevel ?? options.logLevel
        }
    }

    func logLevelOrigin(options: BoxRuntimeOptions) -> BoxRuntimeOptions.LogLevelOrigin {
        if options.logLevelOrigin == .cliFlag { return .cliFlag }
        return server.logLevel != nil ? .configuration : options.logLevelOrigin
    }

    func effectiveLogTarget(options: BoxRuntimeOptions) -> BoxLogTarget {
        switch options.logTargetOrigin {
        case .cliFlag:
            return options.logTarget
        default:
            return server.logTarget.flatMap { BoxLogTarget.parse($0) } ?? options.logTarget
        }
    }

    func logTargetOrigin(options: BoxRuntimeOptions) -> BoxRuntimeOptions.LogTargetOrigin {
        if options.logTargetOrigin == .cliFlag { return .cliFlag }
        return server.logTarget != nil ? .configuration : options.logTargetOrigin
    }

    func effectivePort(options: BoxRuntimeOptions) -> UInt16 {
        switch options.portOrigin {
        case .cliFlag, .environment, .positional:
            return options.port
        default:
            return server.port ?? options.port
        }
    }

    func portOrigin(options: BoxRuntimeOptions) -> BoxRuntimeOptions.PortOrigin {
        if options.portOrigin != .default { return options.portOrigin }
        return server.port != nil ? .configuration : .default
    }

    func effectiveAdminChannelEnabled(options: BoxRuntimeOptions) -> Bool {
        server.adminChannelEnabled ?? options.adminChannelEnabled
    }

    func effectivePortMappingEnabled(options: BoxRuntimeOptions) -> Bool {
        if options.portMappingOrigin == .cliFlag { return options.portMappingRequested }
        return server.portMappingEnabled ?? options.portMappingRequested
    }

    func portMappingOrigin(options: BoxRuntimeOptions) -> BoxRuntimeOptions.PortMappingOrigin {
        if options.portMappingOrigin == .cliFlag { return .cliFlag }
        return server.portMappingEnabled != nil ? .configuration : .default
    }

    func effectiveExternalAddress(options: BoxRuntimeOptions) -> String? {
        if options.externalAddressOrigin == .cliFlag { return options.externalAddressOverride }
        return server.externalAddress ?? options.externalAddressOverride
    }

    func effectiveExternalPort(options: BoxRuntimeOptions) -> UInt16? {
        if options.externalAddressOrigin == .cliFlag { return options.externalPortOverride }
        return server.externalPort ?? options.externalPortOverride
    }

    func externalAddressOrigin(options: BoxRuntimeOptions) -> BoxRuntimeOptions.ExternalAddressOrigin {
        if options.externalAddressOrigin == .cliFlag { return .cliFlag }
        return server.externalAddress != nil ? .configuration : .default
    }
}
