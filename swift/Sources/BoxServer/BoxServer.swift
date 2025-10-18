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

private struct ConnectivitySnapshot: Sendable {
    var globalIPv6Addresses: [String]
    var detectionErrorDescription: String?

    var hasGlobalIPv6: Bool {
        !globalIPv6Addresses.isEmpty
    }
}

/// SwiftNIO based UDP server implementing the Box protocol in cleartext mode.
public enum BoxServer {
    /// Boots the UDP server and keeps running until the channel is closed or the task is cancelled.
    /// - Parameter options: Runtime options resolved from the CLI or configuration file.
    public static func run(with options: BoxRuntimeOptions) async throws {
        var logger = Logger(label: "box.server")
        try enforceNonRoot(logger: logger)

        let homeDirectory = BoxPaths.homeDirectory()
        guard let homeDirectory else {
            throw BoxRuntimeError.storageUnavailable("HOME not set; unable to resolve ~/.box")
        }
        try ensureBoxDirectories(home: homeDirectory, logger: logger)
        let queueRoot = try ensureQueueInfrastructure(logger: logger)

        var effectivePort = options.port
        var portOrigin = options.portOrigin
        if portOrigin == .default,
           let envValue = ProcessInfo.processInfo.environment["BOXD_PORT"],
           let parsed = UInt16(envValue) {
            effectivePort = parsed
            portOrigin = .environment
        }

        let configurationURL = BoxPaths.serverConfigurationURL(explicitPath: options.configurationPath)
        let configurationResult: BoxConfigurationLoadResult?
        do {
            configurationResult = try BoxConfiguration.loadDefault(explicitPath: options.configurationPath)
        } catch {
            if let configURL = configurationURL {
                throw BoxRuntimeError.configurationLoadFailed(configURL)
            } else {
                throw error
            }
        }

        let configuration = configurationResult?.configuration
        let serverConfiguration = configuration?.server
        let commonConfiguration = configuration?.common

        let connectivity = probeConnectivity(logger: logger)
        if let errorDescription = connectivity.detectionErrorDescription {
            logger.debug("connectivity probe failed", metadata: ["error": .string(errorDescription)])
        } else if connectivity.hasGlobalIPv6 {
            logger.info(
                "detected global IPv6 address(es)",
                metadata: [
                    "ipv6": .array(connectivity.globalIPv6Addresses.map { Logger.MetadataValue.string($0) })
                ]
            )
        } else {
            logger.warning("no global IPv6 address detected; IPv4 port mapping or relay will be required for remote access")
        }

        if portOrigin == .default, let configPort = serverConfiguration?.port {
            effectivePort = configPort
            portOrigin = .configuration
        }

        var effectiveLogLevel = options.logLevel
        var logLevelOrigin = options.logLevelOrigin
        if logLevelOrigin == .default, let configLogLevel = serverConfiguration?.logLevel {
            effectiveLogLevel = configLogLevel
            logLevelOrigin = .configuration
        }
        logger.logLevel = effectiveLogLevel
        BoxLogging.update(level: effectiveLogLevel)

        var effectiveLogTarget = options.logTarget
        var logTargetOrigin = options.logTargetOrigin
        if logTargetOrigin == .default, let configTarget = serverConfiguration?.logTarget {
            if let parsedTarget = BoxLogTarget.parse(configTarget) {
                effectiveLogTarget = parsedTarget
                logTargetOrigin = .configuration
            } else {
                logger.warning("invalid log target in configuration", metadata: ["value": "\(configTarget)"])
            }
        }
        BoxLogging.update(target: effectiveLogTarget)

        var adminChannelEnabled = options.adminChannelEnabled
        if let configAdmin = serverConfiguration?.adminChannelEnabled {
            adminChannelEnabled = configAdmin
        }

        let selectedTransport = serverConfiguration?.transportGeneral

        let portMappingRequested = options.portMappingRequested
        let portMappingOrigin = options.portMappingOrigin

        let effectiveNodeId = commonConfiguration?.nodeUUID ?? options.nodeId
        let effectiveUserId = commonConfiguration?.userUUID ?? options.userId

        let startupTimestamp = Date()
        let initialRuntimeState = BoxServerRuntimeState(
            configurationPath: configurationURL?.path,
            configuration: configuration,
            logLevel: effectiveLogLevel,
            logLevelOrigin: logLevelOrigin,
            logTarget: effectiveLogTarget,
            logTargetOrigin: logTargetOrigin,
            adminChannelEnabled: adminChannelEnabled,
            port: effectivePort,
            portOrigin: portOrigin,
            transport: selectedTransport,
            nodeIdentifier: effectiveNodeId,
            userIdentifier: effectiveUserId,
            queueRootPath: queueRoot.path,
            reloadCount: 0,
            lastReloadTimestamp: nil,
            lastReloadStatus: "never",
            lastReloadError: nil,
            hasGlobalIPv6: connectivity.hasGlobalIPv6,
            globalIPv6Addresses: connectivity.globalIPv6Addresses,
            ipv6DetectionError: connectivity.detectionErrorDescription,
            portMappingRequested: portMappingRequested,
            portMappingOrigin: portMappingOrigin,
            portMappingBackend: nil,
            portMappingExternalPort: nil,
            portMappingGateway: nil,
            portMappingService: nil,
            portMappingLeaseSeconds: nil,
            portMappingLastRefresh: nil,
            onlineSince: startupTimestamp,
            lastPresenceUpdate: nil
        )
        let runtimeStateBox = NIOLockedValueBox(initialRuntimeState)

        logStartupSummary(
            logger: logger,
            port: effectivePort,
            portOrigin: portOrigin,
            logLevel: effectiveLogLevel,
            logLevelOrigin: logLevelOrigin,
            logTarget: effectiveLogTarget,
            logTargetOrigin: logTargetOrigin,
            configurationPresent: configurationResult != nil,
            adminChannelEnabled: adminChannelEnabled,
            transport: selectedTransport,
            connectivity: connectivity,
            portMappingRequested: portMappingRequested,
            portMappingOrigin: portMappingOrigin
        )

        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        var portMappingCoordinator: PortMappingCoordinator?
        let store = try await BoxServerStore(root: queueRoot)
        let locationService = LocationServiceCoordinator(store: store, logger: logger)
        try await locationService.bootstrap()
        let statusProvider: @Sendable () async -> String = {
            let snapshot = runtimeStateBox.withLockedValue { $0 }
            let currentTarget = BoxLogging.currentTarget()
            return renderStatus(state: snapshot, logTarget: currentTarget)
        }
        let locationLogger = Logger(label: "box.server.location")
        let publishLocationSnapshot: @Sendable (String) -> LocationServiceNodeRecord = { trigger in
            let record = runtimeStateBox.withLockedValue { state -> LocationServiceNodeRecord in
                state.lastPresenceUpdate = Date()
                return locationServiceRecord(from: state)
            }
            locationLogger.debug("location service snapshot updated", metadata: ["reason": .string(trigger)])
            Task {
                await locationService.publish(record: record)
            }
            return record
        }
        _ = publishLocationSnapshot("startup")
        let identityProvider: @Sendable () -> (UUID, UUID) = {
            runtimeStateBox.withLockedValue { state in
                (state.nodeIdentifier, state.userIdentifier)
            }
        }
        let logTargetUpdater: @Sendable (String) async -> String = { candidate in
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = BoxLogTarget.parse(trimmed) else {
                return adminResponse(["status": "error", "message": "invalid-log-target"])
            }
            BoxLogging.update(target: parsed)
            var originDescription = ""
            runtimeStateBox.withLockedValue { state in
                state.logTarget = parsed
                state.logTargetOrigin = .runtime
                originDescription = "\(state.logTargetOrigin)"
            }
            return adminResponse(["status": "ok", "logTarget": logTargetDescription(parsed), "logTargetOrigin": originDescription])
        }
        let defaultConfigurationPath = configurationURL?.path
        let reloadConfigurationHandler: @Sendable (String?) async -> String = { path in
            let expandedOverride: String?
            if let path, !path.isEmpty {
                expandedOverride = NSString(string: path).expandingTildeInPath
            } else {
                expandedOverride = nil
            }
            var candidatePath = expandedOverride
            if candidatePath == nil {
                candidatePath = runtimeStateBox.withLockedValue { state in
                    state.configurationPath ?? defaultConfigurationPath
                }
            }
            guard let configPath = candidatePath else {
                let timestamp = Date()
                runtimeStateBox.withLockedValue { state in
                    state.reloadCount += 1
                    state.lastReloadTimestamp = timestamp
                    state.lastReloadStatus = "error"
                    state.lastReloadError = "missing-configuration-path"
                }
                return adminResponse(["status": "error", "message": "missing-configuration-path"])
            }

            let url = URL(fileURLWithPath: configPath)
            do {
                let loadResult = try BoxConfiguration.load(from: url)
                let loadedConfiguration = loadResult.configuration
                let loadedServer = loadedConfiguration.server
                let loadedCommon = loadedConfiguration.common

                let timestamp = Date()
                let targetAdjustment = runtimeStateBox.withLockedValue { state -> BoxLogTarget? in
                    state.reloadCount += 1
                    state.lastReloadTimestamp = timestamp
                    state.configurationPath = configPath
                    state.configuration = loadedConfiguration
                    state.lastReloadStatus = "ok"
                    state.lastReloadError = nil
                    state.nodeIdentifier = loadedCommon.nodeUUID
                    state.userIdentifier = loadedCommon.userUUID

                    var targetCandidate: BoxLogTarget?

                    if state.logTargetOrigin != .cliFlag {
                        if let targetString = loadedServer.logTarget, let parsed = BoxLogTarget.parse(targetString) {
                            if state.logTarget != parsed {
                                targetCandidate = parsed
                            }
                            state.logTarget = parsed
                            state.logTargetOrigin = .configuration
                        } else if loadedServer.logTarget != nil {
                            state.lastReloadStatus = "partial"
                            state.lastReloadError = "invalid-log-target"
                        }
                    }

                    if state.logLevelOrigin != .cliFlag {
                        if let level = loadedServer.logLevel {
                            state.logLevel = level
                            state.logLevelOrigin = .configuration
                        } else if state.logLevelOrigin == .configuration {
                            state.logLevelOrigin = .default
                            let defaultLevel: Logger.Level = .info
                            state.logLevel = defaultLevel
                        }
                    }

                    if let transport = loadedServer.transportGeneral {
                        state.transport = transport
                    }
                    if let adminEnabled = loadedServer.adminChannelEnabled {
                        state.adminChannelEnabled = adminEnabled
                    }

                    if state.portMappingOrigin != .cliFlag {
                        if let mappingValue = loadedServer.portMappingEnabled {
                            state.portMappingRequested = mappingValue
                            state.portMappingOrigin = .configuration
                        } else if state.portMappingOrigin == .configuration {
                            state.portMappingRequested = false
                            state.portMappingOrigin = .default
                        }
                        if !state.portMappingRequested {
                            state.portMappingBackend = nil
                            state.portMappingExternalPort = nil
                            state.portMappingGateway = nil
                            state.portMappingService = nil
                            state.portMappingLeaseSeconds = nil
                            state.portMappingLastRefresh = nil
                        }
                    }

                    return targetCandidate
                }

                if let newTarget = targetAdjustment {
                    BoxLogging.update(target: newTarget)
                }

            let locationRecord = publishLocationSnapshot("reload-config")
            let snapshot = runtimeStateBox.withLockedValue { $0 }
            BoxLogging.update(level: snapshot.logLevel)
            var response: [String: Any] = [
                "status": snapshot.lastReloadStatus,
                "path": configPath,
                "logLevel": snapshot.logLevel.rawValue,
                "logLevelOrigin": "\(snapshot.logLevelOrigin)",
                "logTarget": logTargetDescription(snapshot.logTarget),
                "logTargetOrigin": "\(snapshot.logTargetOrigin)",
                "reloadCount": snapshot.reloadCount,
                "hasGlobalIPv6": snapshot.hasGlobalIPv6,
                "globalIPv6Addresses": snapshot.globalIPv6Addresses,
                "portMappingEnabled": snapshot.portMappingRequested,
                "portMappingOrigin": "\(snapshot.portMappingOrigin)"
            ]
            response["nodeUUID"] = snapshot.nodeIdentifier.uuidString
            response["userUUID"] = snapshot.userIdentifier.uuidString
            if let errorDescription = snapshot.ipv6DetectionError {
                response["ipv6ProbeError"] = errorDescription
            }
            response["addresses"] = adminAddressesPayload(from: locationRecord)
            response["connectivity"] = adminConnectivityPayload(from: locationRecord)
            if let timestamp = snapshot.lastReloadTimestamp {
                response["timestamp"] = iso8601String(timestamp)
            }
            if let error = snapshot.lastReloadError {
                response["message"] = error
            }
            return adminResponse(response)
        } catch {
                let timestamp = Date()
                runtimeStateBox.withLockedValue { state in
                    state.reloadCount += 1
                    state.lastReloadTimestamp = timestamp
                    state.lastReloadStatus = "error"
                    state.lastReloadError = "configuration-load-failed"
                }
                return adminResponse([
                    "status": "error",
                    "message": "configuration-load-failed",
                    "path": configPath,
                    "reason": "\(error)"
                ])
            }
        }
        let statsProvider: @Sendable () async -> String = {
            let snapshot = runtimeStateBox.withLockedValue { $0 }
            let currentTarget = BoxLogging.currentTarget()
            return renderStats(state: snapshot, logTarget: currentTarget)
        }

        let locateProvider: @Sendable (UUID) async -> String = { target in
            if let record = await locationService.resolve(nodeUUID: target) {
                return adminResponse([
                    "status": "ok",
                    "record": adminLocationRecordPayload(from: record)
                ])
            }
            let userRecords = await locationService.resolve(userUUID: target)
            if !userRecords.isEmpty {
                return adminResponse([
                    "status": "ok",
                    "user": adminLocationUserPayload(userUUID: target, records: userRecords)
                ])
            }
            return adminResponse([
                "status": "error",
                "message": "node-not-found",
                "nodeUUID": target.uuidString
            ])
        }

        let adminSocketPath = adminChannelEnabled ? BoxPaths.adminSocketPath() : nil
        let adminChannelBox = NIOLockedValueBox<BoxAdminChannelHandle?>(nil)
        if let adminSocketPath {
            do {
                let handle = try await startAdminChannel(
                    on: eventLoopGroup,
                    socketPath: adminSocketPath,
                    logger: logger,
                    statusProvider: statusProvider,
                    logTargetUpdater: logTargetUpdater,
                    reloadConfiguration: reloadConfigurationHandler,
                    statsProvider: statsProvider,
                    locateProvider: locateProvider
                )
                adminChannelBox.withLockedValue { $0 = handle }
                logger.info("admin channel ready", metadata: ["socket": "\(adminSocketPath)"])
            } catch {
                logger.warning("unable to start admin channel", metadata: ["error": "\(error)"])
            }
        }

        #if !os(Windows)
        defer {
            if let adminSocketPath {
                try? FileManager.default.removeItem(atPath: adminSocketPath)
            }
        }
        #else
        defer {}
        #endif

        let pipelineLogger = logger
        let locationAuthorizer: @Sendable (UUID, UUID) async -> Bool = { node, user in
            await locationService.authorize(nodeUUID: node, userUUID: user)
        }
        let locationResolver: @Sendable (UUID) async -> LocationServiceNodeRecord? = { target in
            await locationService.resolve(nodeUUID: target)
        }

        let bootstrap = DatagramBootstrap(group: eventLoopGroup)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandler(
                    BoxServerHandler(
                        logger: pipelineLogger,
                        allocator: channel.allocator,
                        store: store,
                        identityProvider: identityProvider,
                        authorizer: locationAuthorizer,
                        locationResolver: locationResolver
                    )
                )
            }

        do {
            let channel = try await bootstrap.bind(host: options.address, port: Int(effectivePort)).get()
            let channelBox = UncheckedSendableBox(channel)
            let localAddress = channel.localAddress
            var resolvedHost = options.address
            var resolvedPort = Int(effectivePort)
            if let observedPort = localAddress?.port, observedPort > 0 {
                resolvedPort = observedPort
            }
            if let observedHost = localAddress?.ipAddress {
                resolvedHost = observedHost
            }
            if resolvedPort > 0 {
                let finalPort = UInt16(resolvedPort)
                effectivePort = finalPort
                let portChanged = runtimeStateBox.withLockedValue { state -> Bool in
                    let changed = state.port != finalPort
                    state.port = finalPort
                    return changed
                }
                if portChanged {
                    _ = publishLocationSnapshot("port-change")
                }
            }
            if portMappingRequested && portMappingCoordinator == nil {
                let coordinator = PortMappingCoordinator(
                    logger: logger,
                    port: effectivePort,
                    origin: portMappingOrigin
                ) { snapshot in
                    runtimeStateBox.withLockedValue { state in
                        if let snapshot {
                            state.portMappingBackend = snapshot.backend
                            state.portMappingExternalPort = snapshot.externalPort
                            state.portMappingGateway = snapshot.gateway
                            state.portMappingService = snapshot.service
                            state.portMappingLeaseSeconds = snapshot.lifetime
                            state.portMappingLastRefresh = snapshot.refreshedAt
                        } else {
                            state.portMappingBackend = nil
                            state.portMappingExternalPort = nil
                            state.portMappingGateway = nil
                            state.portMappingService = nil
                            state.portMappingLeaseSeconds = nil
                            state.portMappingLastRefresh = nil
                        }
                    }
                    _ = publishLocationSnapshot(snapshot != nil ? "port-mapping-refresh" : "port-mapping-clear")
                }
                coordinator.start()
                portMappingCoordinator = coordinator
            }
            var metadata: Logger.Metadata = [
                "address": .string(resolvedHost),
                "port": .string("\(effectivePort)")
            ]
            if let localAddress {
                metadata["localAddress"] = .string(localAddress.description)
            }
            let listenDescription: String
            if let localAddress {
                if let ip = localAddress.ipAddress {
                    listenDescription = "\(ip):\(effectivePort)"
                } else {
                    listenDescription = localAddress.description
                }
            } else {
                listenDescription = "\(resolvedHost):\(effectivePort)"
            }
            logger.info("server listening on \(listenDescription)", metadata: metadata)

            let cancellationLogLevel = logger.logLevel
            try await withTaskCancellationHandler {
                try await channelBox.value.closeFuture.get()
            } onCancel: {
                var cancellationLogger = Logging.Logger(label: "box.server.cancel")
                cancellationLogger.logLevel = cancellationLogLevel
                cancellationLogger.info("server cancellation requested")
                channelBox.value.close(promise: nil)
                if let handle = adminChannelBox.withLockedValue({ $0 }) {
                    initiateAdminChannelShutdown(handle)
                }
            }

            if let handle = adminChannelBox.withLockedValue({ $0 }) {
                await waitForAdminChannelShutdown(handle)
            }

            portMappingCoordinator?.stop()
            logger.info("server stopped")
            try await eventLoopGroup.shutdownGracefully()
        } catch {
            logger.error("server failed: \(error)")
            portMappingCoordinator?.stop()
            if let handle = adminChannelBox.withLockedValue({ $0 }) {
                initiateAdminChannelShutdown(handle)
                await waitForAdminChannelShutdown(handle)
            }
            try? await eventLoopGroup.shutdownGracefully()
            throw error
        }
    }
}

/// Captures mutable runtime state exposed over the admin channel and used for reload decisions.
private struct BoxServerRuntimeState: Sendable {
    var configurationPath: String?
    var configuration: BoxConfiguration?
    var logLevel: Logger.Level
    var logLevelOrigin: BoxRuntimeOptions.LogLevelOrigin
    var logTarget: BoxLogTarget
    var logTargetOrigin: BoxRuntimeOptions.LogTargetOrigin
    var adminChannelEnabled: Bool
    var port: UInt16
    var portOrigin: BoxRuntimeOptions.PortOrigin
    var transport: String?
    var nodeIdentifier: UUID
    var userIdentifier: UUID
    var queueRootPath: String?
    var reloadCount: Int
    var lastReloadTimestamp: Date?
    var lastReloadStatus: String
    var lastReloadError: String?
    var hasGlobalIPv6: Bool
    var globalIPv6Addresses: [String]
    var ipv6DetectionError: String?
    var portMappingRequested: Bool
    var portMappingOrigin: BoxRuntimeOptions.PortMappingOrigin
    var portMappingBackend: String?
    var portMappingExternalPort: UInt16?
    var portMappingGateway: String?
    var portMappingService: String?
    var portMappingLeaseSeconds: UInt32?
    var portMappingLastRefresh: Date?
    var onlineSince: Date
    var lastPresenceUpdate: Date?
}

/// Represents an active admin channel implementation (NIO channel or Windows named pipe).
private enum BoxAdminChannelHandle {
    case nio(Channel)
    #if os(Windows)
    case pipe(BoxAdminNamedPipeServer)
    #endif
}

extension BoxAdminChannelHandle: @unchecked Sendable {}

/// Channel handler that decodes incoming datagrams and produces responses.
private final class BoxServerHandler: ChannelInboundHandler {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    private let logger: Logger
    private let allocator: ByteBufferAllocator
    private let store: BoxServerStore
    private let identityProvider: @Sendable () -> (UUID, UUID)
    private let authorizer: @Sendable (UUID, UUID) async -> Bool
    private let locationResolver: @Sendable (UUID) async -> LocationServiceNodeRecord?
    private let jsonEncoder: JSONEncoder

    init(
        logger: Logger,
        allocator: ByteBufferAllocator,
        store: BoxServerStore,
        identityProvider: @escaping @Sendable () -> (UUID, UUID),
        authorizer: @escaping @Sendable (UUID, UUID) async -> Bool,
        locationResolver: @escaping @Sendable (UUID) async -> LocationServiceNodeRecord?
    ) {
        self.logger = logger
        self.allocator = allocator
        self.store = store
        self.identityProvider = identityProvider
        self.authorizer = authorizer
        self.locationResolver = locationResolver
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.jsonEncoder = encoder
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        var datagram = envelope.data

        do {
            let frame = try BoxCodec.decodeFrame(from: &datagram)
            try handle(frame: frame, from: envelope.remoteAddress, context: context)
        } catch {
            logger.warning("failed to decode datagram", metadata: ["error": "\(error)", "remote": "\(envelope.remoteAddress)"])
        }
    }

    private func handle(frame: BoxCodec.Frame, from remote: SocketAddress, context: ChannelHandlerContext) throws {
        var payload = frame.payload
        switch frame.command {
        case .hello:
            try respondToHello(payload: &payload, frame: frame, remote: remote, context: context)
        case .status:
            try respondToStatus(frame: frame, remote: remote, context: context)
        case .put:
            try handlePut(payload: &payload, frame: frame, remote: remote, context: context)
        case .get:
            try handleGet(payload: &payload, frame: frame, remote: remote, context: context)
        case .locate, .search:
            try handleLocate(payload: &payload, frame: frame, remote: remote, context: context)
        default:
            let statusPayload = BoxCodec.encodeStatusPayload(
                status: .badRequest,
                message: "unknown-command",
                allocator: allocator
            )
            send(command: .status, requestId: frame.requestId, payload: statusPayload, to: remote, context: context)
        }
    }

    private func respondToHello(payload: inout ByteBuffer, frame: BoxCodec.Frame, remote: SocketAddress, context: ChannelHandlerContext) throws {
        let hello = try BoxCodec.decodeHelloPayload(from: &payload)
        guard hello.supportedVersions.contains(1) else {
            logger.info("HELLO without compatible version", metadata: ["remote": "\(remote)"])
            let statusPayload = BoxCodec.encodeStatusPayload(
                status: .badRequest,
                message: "unsupported-version",
                allocator: allocator
            )
            send(command: .status, requestId: frame.requestId, payload: statusPayload, to: remote, context: context)
            return
        }
        let responsePayload = try BoxCodec.encodeHelloPayload(status: .ok, versions: [1], allocator: allocator)
        send(command: .hello, requestId: frame.requestId, payload: responsePayload, to: remote, context: context)
    }

    private func respondToStatus(frame: BoxCodec.Frame, remote: SocketAddress, context: ChannelHandlerContext) throws {
        var payload = frame.payload
        let status = try BoxCodec.decodeStatusPayload(from: &payload)
        logger.debug("STATUS received", metadata: ["status": "\(status.status)", "message": "\(status.message)"])
        let pongPayload = BoxCodec.encodeStatusPayload(status: .ok, message: "pong", allocator: allocator)
        send(command: .status, requestId: frame.requestId, payload: pongPayload, to: remote, context: context)
    }

    private func handlePut(payload: inout ByteBuffer, frame: BoxCodec.Frame, remote: SocketAddress, context: ChannelHandlerContext) throws {
        let putPayload = try BoxCodec.decodePutPayload(from: &payload)
        let queuePath = putPayload.queuePath
        let storedObject = BoxStoredObject(
            contentType: putPayload.contentType,
            data: putPayload.data,
            nodeId: frame.nodeId,
            userId: frame.userId
        )
        let store = self.store
        let logger = self.logger
        let allocator = self.allocator
        let requestId = frame.requestId
        let eventLoop = context.eventLoop
        let contextBox = UncheckedSendableBox(context)
        let remoteAddress = remote

        Task {
            do {
                try await store.put(storedObject, into: queuePath)
                logger.info(
                    "stored object on queue \(queuePath)",
                    metadata: [
                        "queue": .string(queuePath),
                        "bytes": .string("\(storedObject.data.count)"),
                        "originNode": .string(storedObject.nodeId.uuidString),
                        "originUser": .string(storedObject.userId.uuidString)
                    ]
                )
                eventLoop.execute {
                    let statusPayload = BoxCodec.encodeStatusPayload(status: .ok, message: "stored", allocator: allocator)
                    let ctx = contextBox.value
                    self.send(command: .status, requestId: requestId, payload: statusPayload, to: remoteAddress, context: ctx)
                }
            } catch {
                logger.error(
                    "failed to store object",
                    metadata: ["queue": .string(queuePath), "error": .string("\(error)")]
                )
                eventLoop.execute {
                    let statusPayload = BoxCodec.encodeStatusPayload(status: .internalError, message: "storage-error", allocator: allocator)
                    let ctx = contextBox.value
                    self.send(command: .status, requestId: requestId, payload: statusPayload, to: remoteAddress, context: ctx)
                }
            }
        }
    }

    private func handleGet(payload: inout ByteBuffer, frame: BoxCodec.Frame, remote: SocketAddress, context: ChannelHandlerContext) throws {
        let getPayload = try BoxCodec.decodeGetPayload(from: &payload)
        let queuePath = getPayload.queuePath
        let store = self.store
        let allocator = self.allocator
        let logger = self.logger
        let requestId = frame.requestId
        let eventLoop = context.eventLoop
        let contextBox = UncheckedSendableBox(context)
        let remoteAddress = remote

        Task {
            do {
                if let object = try await store.popOldest(from: queuePath) {
                    eventLoop.execute {
                        let responsePayload = BoxCodec.encodePutPayload(
                            BoxCodec.PutPayload(queuePath: queuePath, contentType: object.contentType, data: object.data),
                            allocator: allocator
                        )
                        let ctx = contextBox.value
                        self.send(command: .put, requestId: requestId, payload: responsePayload, to: remoteAddress, context: ctx)
                    }
                } else {
                    eventLoop.execute {
                        let statusPayload = BoxCodec.encodeStatusPayload(status: .badRequest, message: "not-found", allocator: allocator)
                        let ctx = contextBox.value
                        self.send(command: .status, requestId: requestId, payload: statusPayload, to: remoteAddress, context: ctx)
                    }
                }
            } catch {
                logger.error(
                    "failed to fetch object",
                    metadata: ["queue": .string(queuePath), "error": .string("\(error)")]
                )
                eventLoop.execute {
                    let statusPayload = BoxCodec.encodeStatusPayload(status: .internalError, message: "storage-error", allocator: allocator)
                    let ctx = contextBox.value
                    self.send(command: .status, requestId: requestId, payload: statusPayload, to: remoteAddress, context: ctx)
                }
            }
        }
    }

    private func handleLocate(payload: inout ByteBuffer, frame: BoxCodec.Frame, remote: SocketAddress, context: ChannelHandlerContext) throws {
        let locatePayload = try BoxCodec.decodeLocatePayload(from: &payload)
        let allocator = self.allocator
        let logger = self.logger
        let authorizer = self.authorizer
        let resolver = self.locationResolver
        let encoder = self.jsonEncoder
        let eventLoop = context.eventLoop
        let contextBox = UncheckedSendableBox(context)
        let remoteAddress = remote
        let requestId = frame.requestId
        let requesterNode = frame.nodeId
        let requesterUser = frame.userId
        let targetNode = locatePayload.nodeUUID

        Task {
            let permitted = await authorizer(requesterNode, requesterUser)
            guard permitted else {
                eventLoop.execute {
                    logger.debug(
                        "locate request rejected",
                        metadata: [
                            "requestNode": .string(requesterNode.uuidString),
                            "requestUser": .string(requesterUser.uuidString)
                        ]
                    )
                    let statusPayload = BoxCodec.encodeStatusPayload(status: .unauthorized, message: "unknown-client", allocator: allocator)
                    let ctx = contextBox.value
                    self.send(command: .status, requestId: requestId, payload: statusPayload, to: remoteAddress, context: ctx)
                }
                return
            }

            if let record = await resolver(targetNode) {
                eventLoop.execute {
                    do {
                        let data = try encoder.encode(record)
                        logger.debug(
                            "locate request served",
                            metadata: [
                                "target": .string(record.nodeUUID.uuidString),
                                "requestNode": .string(requesterNode.uuidString)
                            ]
                        )
                        let responsePayload = BoxCodec.encodePutPayload(
                            BoxCodec.PutPayload(queuePath: "/location", contentType: "application/json; charset=utf-8", data: [UInt8](data)),
                            allocator: allocator
                        )
                        let ctx = contextBox.value
                        self.send(command: .put, requestId: requestId, payload: responsePayload, to: remoteAddress, context: ctx)
                    } catch {
                        logger.error("failed to encode location record", metadata: ["error": .string("\(error)")])
                        let statusPayload = BoxCodec.encodeStatusPayload(status: .internalError, message: "encoding-error", allocator: allocator)
                        let ctx = contextBox.value
                        self.send(command: .status, requestId: requestId, payload: statusPayload, to: remoteAddress, context: ctx)
                    }
                }
            } else {
                eventLoop.execute {
                    logger.debug(
                        "locate target missing",
                        metadata: [
                            "target": .string(targetNode.uuidString),
                            "requestNode": .string(requesterNode.uuidString)
                        ]
                    )
                    let statusPayload = BoxCodec.encodeStatusPayload(status: .notFound, message: "node-not-found", allocator: allocator)
                    let ctx = contextBox.value
                    self.send(command: .status, requestId: requestId, payload: statusPayload, to: remoteAddress, context: ctx)
                }
            }
        }
    }

    private func send(command: BoxCodec.Command, requestId: UUID, payload: ByteBuffer, to remote: SocketAddress, context: ChannelHandlerContext) {
        let (nodeId, userId) = identityProvider()
        let frame = BoxCodec.Frame(command: command, requestId: requestId, nodeId: nodeId, userId: userId, payload: payload)
        let datagram = BoxCodec.encodeFrame(frame, allocator: allocator)
        let envelope = AddressedEnvelope(remoteAddress: remote, data: datagram)
        context.writeAndFlush(wrapOutboundOut(envelope), promise: nil)
    }
}

extension BoxServerHandler: @unchecked Sendable {}

/// Dispatches admin commands to the appropriate runtime closures.
struct BoxAdminCommandDispatcher: Sendable {
    private let statusProvider: @Sendable () async -> String
    private let logTargetUpdater: @Sendable (String) async -> String
    private let reloadConfiguration: @Sendable (String?) async -> String
    private let statsProvider: @Sendable () async -> String
    private let locateNode: @Sendable (UUID) async -> String

    init(
        statusProvider: @escaping @Sendable () async -> String,
        logTargetUpdater: @escaping @Sendable (String) async -> String,
        reloadConfiguration: @escaping @Sendable (String?) async -> String,
        statsProvider: @escaping @Sendable () async -> String,
        locateNode: @escaping @Sendable (UUID) async -> String
    ) {
        self.statusProvider = statusProvider
        self.logTargetUpdater = logTargetUpdater
        self.reloadConfiguration = reloadConfiguration
        self.statsProvider = statsProvider
        self.locateNode = locateNode
    }

    /// Processes a raw admin command string and returns the JSON response payload.
    /// - Parameter rawValue: Command string as received on the transport.
    /// - Returns: JSON response (without trailing newline).
    func process(_ rawValue: String) async -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return adminResponse(["status": "error", "message": "empty-command"])
        }
        let command = parse(trimmed)
        switch command {
        case .status:
            return await statusProvider()
        case .ping:
            return adminResponse(["status": "ok", "message": "pong"])
        case .logTarget(let target):
            return await logTargetUpdater(target)
        case .reloadConfig(let path):
            return await reloadConfiguration(path)
        case .stats:
            return await statsProvider()
        case .locate(let node):
            return await locateNode(node)
        case .invalid(let message):
            return adminResponse(["status": "error", "message": message])
        case .unknown(let value):
            return adminResponse(["status": "error", "message": "unknown-command", "command": value])
        }
    }

    private func parse(_ command: String) -> BoxAdminParsedCommand {
        if command == "status" {
            return .status
        }
        if command == "ping" {
            return .ping
        }
        if command.hasPrefix("log-target") {
            let remainder = command.dropFirst("log-target".count).trimmingCharacters(in: .whitespaces)
            if remainder.isEmpty {
                return .invalid("missing-log-target")
            }
            if remainder.hasPrefix("{") {
                guard let target = extractStringField(from: String(remainder), field: "target") else {
                    return .invalid("invalid-log-target-payload")
                }
                return .logTarget(target)
            }
            return .logTarget(String(remainder))
        }
        if command.hasPrefix("reload-config") {
            let remainder = command.dropFirst("reload-config".count).trimmingCharacters(in: .whitespaces)
            if remainder.isEmpty {
                return .reloadConfig(nil)
            }
            if remainder.hasPrefix("{") {
                guard let path = extractStringField(from: String(remainder), field: "path") else {
                    return .invalid("invalid-reload-config-payload")
                }
                return .reloadConfig(path)
            }
            return .reloadConfig(String(remainder))
        }
        if command == "stats" {
            return .stats
        }
        if command.hasPrefix("locate") {
            let remainder = command.dropFirst("locate".count).trimmingCharacters(in: .whitespaces)
            guard !remainder.isEmpty else {
                return .invalid("missing-locate-target")
            }
            if remainder.hasPrefix("{") {
                guard let nodeString = extractStringField(from: String(remainder), field: "node"),
                      let uuid = UUID(uuidString: nodeString) else {
                    return .invalid("invalid-locate-payload")
                }
                return .locate(uuid)
            }
            guard let uuid = UUID(uuidString: remainder) else {
                return .invalid("invalid-node-uuid")
            }
            return .locate(uuid)
        }
        return .unknown(command)
    }

    /// Attempts to extract a string field from a JSON object encoded after the command verb.
    /// - Parameters:
    ///   - jsonString: JSON payload appended to the command.
    ///   - field: Expected key within the JSON object.
    /// - Returns: String value when present and valid, otherwise `nil`.
    private func extractStringField(from jsonString: String, field: String) -> String? {
        guard let data = jsonString.data(using: .utf8) else {
            return nil
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: data, options: []),
            let dictionary = object as? [String: Any],
            let value = dictionary[field] as? String,
            !value.isEmpty
        else {
            return nil
        }
        return value
    }
}

/// Handler responding to admin channel requests (status, ping, log target updates and future commands).
private final class BoxAdminChannelHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let logger: Logger
    private let dispatcher: BoxAdminCommandDispatcher

    init(logger: Logger, dispatcher: BoxAdminCommandDispatcher) {
        self.logger = logger
        self.dispatcher = dispatcher
    }

    func channelActive(context: ChannelHandlerContext) {
        logger.debug("admin connection accepted")
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let command = buffer.readString(length: buffer.readableBytes), !command.isEmpty else {
            context.close(promise: nil)
            return
        }
        let dispatcher = self.dispatcher
        let contextBox = UncheckedSendableBox(context)
        let eventLoop = context.eventLoop
        Task {
            let response = await dispatcher.process(command)
            eventLoop.execute {
                self.write(response: response, context: contextBox.value)
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.warning("admin channel error", metadata: ["error": "\(error)"])
        context.close(promise: nil)
    }

    private func write(response: String, context: ChannelHandlerContext) {
        var outBuffer = context.channel.allocator.buffer(capacity: response.utf8.count + 1)
        outBuffer.writeString(response)
        outBuffer.writeString("\n")
        context.writeAndFlush(wrapOutboundOut(outBuffer), promise: nil)
        context.close(promise: nil)
    }
}

extension BoxAdminChannelHandler: @unchecked Sendable {}

/// Enumerates the supported admin commands once parsed.
private enum BoxAdminParsedCommand {
    case status
    case ping
    case logTarget(String)
    case reloadConfig(String?)
    case stats
    case locate(UUID)
    case invalid(String)
    case unknown(String)
}

#if os(Windows)
/// Minimal named-pipe based admin channel implementation for Windows.
private final class BoxAdminNamedPipeServer: @unchecked Sendable {
    private let path: String
    private let logger: Logger
    private let dispatcher: BoxAdminCommandDispatcher
    private let shouldStop = NIOLockedValueBox(false)
    private var task: Task<Void, Never>?
    private let securityAttributes: UnsafeMutablePointer<SECURITY_ATTRIBUTES>?
    private let securityDescriptor: PSECURITY_DESCRIPTOR?

    init(path: String, logger: Logger, dispatcher: BoxAdminCommandDispatcher) {
        self.path = path
        self.logger = logger
        self.dispatcher = dispatcher
        let securityContext = Self.makeSecurityAttributes(logger: logger)
        self.securityAttributes = securityContext?.attributes
        self.securityDescriptor = securityContext?.descriptor
    }

    /// Starts the background listener loop on a detached task.
    func start() {
        guard task == nil else { return }
        let pipePath = path
        task = Task.detached { [weak self] in
            guard let self else { return }
            await self.runLoop(path: pipePath)
        }
    }

    /// Signals the listener loop to terminate.
    func requestStop() {
        shouldStop.withLockedValue { $0 = true }
        Self.poke(path: path)
    }

    /// Waits for the background loop to finish.
    func waitUntilStopped() async {
        if let task = task {
            await task.value
        }
    }

    private func runLoop(path: String) async {
        let bufferSize: DWORD = 4096
        if securityAttributes == nil {
            logger.warning("admin pipe security: using default ACL (Windows descriptor creation failed)")
        }
        while !shouldStop.withLockedValue({ $0 }) {
            let handle: HANDLE = path.withCString(encodedAs: UTF16.self) { pointer in
                CreateNamedPipeW(
                    pointer,
                    DWORD(PIPE_ACCESS_DUPLEX),
                    DWORD(PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT),
                    DWORD(1),
                    bufferSize,
                    bufferSize,
                    DWORD(0),
                    securityAttributes
                )
            }

            if handle == INVALID_HANDLE_VALUE {
                let error = GetLastError()
                logger.error("admin pipe creation failed", metadata: ["error": "\(error)"])
                return
            }

            defer { CloseHandle(handle) }

            let connected = ConnectNamedPipe(handle, nil)
            if !connected {
                let error = GetLastError()
                if error != ERROR_PIPE_CONNECTED {
                    logger.warning("admin pipe connect failed", metadata: ["error": "\(error)"])
                    continue
                }
            }

            if shouldStop.withLockedValue({ $0 }) {
                DisconnectNamedPipe(handle)
                break
            }

            var buffer = [UInt8](repeating: 0, count: Int(bufferSize))
            var bytesRead: DWORD = 0
            let readResult = ReadFile(handle, &buffer, DWORD(buffer.count), &bytesRead, nil)
            if !readResult || bytesRead == 0 {
                DisconnectNamedPipe(handle)
                continue
            }

            let commandData = buffer.prefix(Int(bytesRead))
            let command = String(bytes: commandData, encoding: .utf8) ?? ""
            let responsePayload = await dispatcher.process(command)
            let response = responsePayload.hasSuffix("\n") ? responsePayload : responsePayload + "\n"
            let responseBytes = Array(response.utf8)
            var bytesWritten: DWORD = 0
            _ = WriteFile(handle, responseBytes, DWORD(responseBytes.count), &bytesWritten, nil)
            FlushFileBuffers(handle)
            DisconnectNamedPipe(handle)
        }
    }

    /// Connects to the pipe once to unblock any pending `ConnectNamedPipe` call during shutdown.
    private static func poke(path: String) {
        path.withCString(encodedAs: UTF16.self) { pointer in
            let handle = CreateFileW(pointer, DWORD(GENERIC_READ | GENERIC_WRITE), DWORD(0), nil, DWORD(OPEN_EXISTING), DWORD(0), nil)
            if handle != INVALID_HANDLE_VALUE {
                CloseHandle(handle)
            }
        }
    }

    deinit {
        if let descriptor = securityDescriptor {
            _ = LocalFree(descriptor)
        }
        if let pointer = securityAttributes {
            pointer.deinitialize(count: 1)
            pointer.deallocate()
        }
    }

    private static func makeSecurityAttributes(
        logger: Logger
    ) -> (attributes: UnsafeMutablePointer<SECURITY_ATTRIBUTES>, descriptor: PSECURITY_DESCRIPTOR)? {
        let sddl = "D:P(A;;FA;;;SY)(A;;FA;;;OW)"
        return sddl.withCString(encodedAs: UTF16.self) { pointer -> (UnsafeMutablePointer<SECURITY_ATTRIBUTES>, PSECURITY_DESCRIPTOR)? in
            var securityDescriptor: PSECURITY_DESCRIPTOR?
            let conversionResult = ConvertStringSecurityDescriptorToSecurityDescriptorW(
                pointer,
                DWORD(SDDL_REVISION_1),
                &securityDescriptor,
                nil
            )
            guard conversionResult != 0, let descriptor = securityDescriptor else {
                let error = GetLastError()
                logger.warning("admin pipe security descriptor creation failed", metadata: ["error": "\(error)"])
                return nil
            }

            let attributes = UnsafeMutablePointer<SECURITY_ATTRIBUTES>.allocate(capacity: 1)
            attributes.initialize(to: SECURITY_ATTRIBUTES(
                nLength: DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size),
                lpSecurityDescriptor: descriptor,
                bInheritHandle: FALSE
            ))
            return (attributes, descriptor)
        }
    }
}
#endif

// MARK: - Helpers

/// Enforces the non-root execution policy on Unix-like platforms.
/// - Parameter logger: Logger used for diagnostics when enforcement is skipped.
/// - Throws: `BoxRuntimeError.forbiddenOperation` if the daemon is started as root.
private func enforceNonRoot(logger: Logger) throws {
    #if os(Linux) || os(macOS)
    if geteuid() == 0 {
        throw BoxRuntimeError.forbiddenOperation("boxd must not run as root")
    }
    #else
    logger.debug("non-root enforcement skipped on this platform")
    #endif
}

/// Ensures `~/.box` and `~/.box/run` exist with restrictive permissions.
/// - Parameters:
///   - home: Home directory resolved earlier.
///   - logger: Logger used for warnings when the path cannot be resolved.
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

/// Creates a directory if missing and enforces `0700` permissions.
/// - Parameter url: Directory to create.
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

/// Ensures the queue storage hierarchy exists and that the mandatory `INBOX` queue is present.
/// - Parameter logger: Logger used to emit diagnostics before failure.
/// - Returns: URL pointing to the queue root directory.
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

/// Captures file-system metrics derived from the queue storage root.
private struct QueueMetrics {
    var count: Int
    var objectCount: Int
    var freeBytes: UInt64?
}

/// Computes the number of queues (directories) and free disk space under the queue root.
private func queueMetrics(at root: URL) -> QueueMetrics {
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

    var freeBytes: UInt64?
    if let attributes = try? fileManager.attributesOfFileSystem(forPath: root.path),
       let freeSize = attributes[.systemFreeSize] as? NSNumber {
        freeBytes = freeSize.uint64Value
    }

    if queueCount < 1 {
        queueCount = 1
    }
    return QueueMetrics(count: queueCount, objectCount: objectCount, freeBytes: freeBytes)
}

/// Executes an async operation synchronously using a semaphore bridge.
/// - Parameter operation: Asynchronous closure whose result is required synchronously.
/// - Returns: Result of the asynchronous operation.
/// Binds the admin channel on the provided UNIX domain socket path.
/// - Parameters:
///   - eventLoopGroup: Event loop group used for the server bootstrap.
///   - socketPath: Filesystem path of the admin socket.
///   - logger: Logger used for diagnostics.
///   - statusProvider: Closure producing the JSON payload returned for `status`.
///   - logTargetUpdater: Closure handling runtime log-target updates.
///   - reloadConfiguration: Closure invoked when a configuration reload is requested.
///   - statsProvider: Closure providing runtime statistics (stub until implemented).
/// - Returns: The bound channel ready to accept admin connections.
private func startAdminChannel(
    on eventLoopGroup: EventLoopGroup,
    socketPath: String,
    logger: Logger,
    statusProvider: @escaping @Sendable () async -> String,
    logTargetUpdater: @escaping @Sendable (String) async -> String,
    reloadConfiguration: @escaping @Sendable (String?) async -> String,
    statsProvider: @escaping @Sendable () async -> String,
    locateProvider: @escaping @Sendable (UUID) async -> String
) async throws -> BoxAdminChannelHandle {
    let dispatcher = BoxAdminCommandDispatcher(
        statusProvider: statusProvider,
        logTargetUpdater: logTargetUpdater,
        reloadConfiguration: reloadConfiguration,
        statsProvider: statsProvider,
        locateNode: locateProvider
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

/// Builds a JSON status payload for the admin channel.
/// - Parameters:
///   - state: Current runtime state snapshot.
///   - store: Shared object store (used to expose queue count).
///   - logTarget: Active log target reported by the logging subsystem.
/// - Returns: A JSON string summarising the current server state.
private func renderStatus(state: BoxServerRuntimeState, logTarget: BoxLogTarget) -> String {
    var payload: [String: Any] = [
        "status": "ok",
        "port": Int(state.port),
        "portOrigin": "\(state.portOrigin)",
        "logLevel": state.logLevel.rawValue,
        "logLevelOrigin": "\(state.logLevelOrigin)",
        "logTarget": logTargetDescription(logTarget),
        "logTargetOrigin": "\(state.logTargetOrigin)",
        "adminChannel": state.adminChannelEnabled ? "enabled" : "disabled",
        "transport": state.transport ?? "clear",
        "reloadCount": state.reloadCount,
        "hasGlobalIPv6": state.hasGlobalIPv6,
        "globalIPv6Addresses": state.globalIPv6Addresses,
        "portMappingEnabled": state.portMappingRequested,
        "portMappingOrigin": "\(state.portMappingOrigin)"
    ]
    if let backend = state.portMappingBackend {
        payload["portMappingBackend"] = backend
    }
    if let external = state.portMappingExternalPort {
        payload["portMappingExternalPort"] = Int(external)
    }
    if let gateway = state.portMappingGateway {
        payload["portMappingGateway"] = gateway
    }
    if let service = state.portMappingService {
        payload["portMappingService"] = service
    }
    if let lease = state.portMappingLeaseSeconds {
        payload["portMappingLeaseSeconds"] = lease
    }
    if let refreshed = state.portMappingLastRefresh {
        payload["portMappingRefreshedAt"] = iso8601String(refreshed)
    }
    if let backend = state.portMappingBackend {
        payload["portMappingBackend"] = backend
    }
    if let external = state.portMappingExternalPort {
        payload["portMappingExternalPort"] = Int(external)
    }
    if let gateway = state.portMappingGateway {
        payload["portMappingGateway"] = gateway
    }
    if let service = state.portMappingService {
        payload["portMappingService"] = service
    }
    if let lease = state.portMappingLeaseSeconds {
        payload["portMappingLeaseSeconds"] = lease
    }
    if let refreshed = state.portMappingLastRefresh {
        payload["portMappingRefreshedAt"] = iso8601String(refreshed)
    }
    if let path = state.configurationPath {
        payload["configPath"] = path
    }
    payload["nodeUUID"] = state.nodeIdentifier.uuidString
    payload["userUUID"] = state.userIdentifier.uuidString
    if let detectionError = state.ipv6DetectionError {
        payload["ipv6ProbeError"] = detectionError
    }
    if let queueRootPath = state.queueRootPath {
        payload["queueRoot"] = queueRootPath
        let metrics = queueMetrics(at: URL(fileURLWithPath: queueRootPath, isDirectory: true))
        payload["queueCount"] = metrics.count
        payload["objects"] = metrics.objectCount
        payload["queues"] = metrics.count
        if let freeBytes = metrics.freeBytes {
            payload["queueFreeBytes"] = freeBytes
        }
    } else {
        payload["queueCount"] = 1
        payload["objects"] = 0
        payload["queues"] = 1
    }
    let locationRecord = locationServiceRecord(from: state)
    payload["addresses"] = adminAddressesPayload(from: locationRecord)
    payload["connectivity"] = adminConnectivityPayload(from: locationRecord)
    if let presenceTimestamp = state.lastPresenceUpdate {
        payload["lastPresenceUpdate"] = iso8601String(presenceTimestamp)
    }
    if let timestamp = state.lastReloadTimestamp {
        payload["lastReload"] = iso8601String(timestamp)
    }
    if state.lastReloadStatus != "never" {
        payload["lastReloadStatus"] = state.lastReloadStatus
    }
    if let error = state.lastReloadError {
        payload["lastReloadMessage"] = error
    }
    return adminResponse(payload)
}

/// Produces a JSON payload summarising runtime metrics for the admin `stats` command.
/// - Parameters:
///   - state: Current runtime state snapshot.
///   - store: Shared object store exposing queue counters.
///   - logTarget: Active log target reported by the logging subsystem.
/// - Returns: A JSON string describing runtime metrics.
private func renderStats(state: BoxServerRuntimeState, logTarget: BoxLogTarget) -> String {
    var payload: [String: Any] = [
        "status": "ok",
        "timestamp": iso8601String(Date()),
        "port": Int(state.port),
        "logLevel": state.logLevel.rawValue,
        "logLevelOrigin": "\(state.logLevelOrigin)",
        "logTarget": logTargetDescription(logTarget),
        "logTargetOrigin": "\(state.logTargetOrigin)",
        "transport": state.transport ?? "clear",
        "adminChannel": state.adminChannelEnabled ? "enabled" : "disabled",
        "reloadCount": state.reloadCount,
        "hasGlobalIPv6": state.hasGlobalIPv6,
        "globalIPv6Addresses": state.globalIPv6Addresses,
        "portMappingEnabled": state.portMappingRequested,
        "portMappingOrigin": "\(state.portMappingOrigin)"
    ]
    if let path = state.configurationPath {
        payload["configPath"] = path
    }
    if let lastReload = state.lastReloadTimestamp {
        payload["lastReload"] = iso8601String(lastReload)
    }
    payload["nodeUUID"] = state.nodeIdentifier.uuidString
    payload["userUUID"] = state.userIdentifier.uuidString
    if let detectionError = state.ipv6DetectionError {
        payload["ipv6ProbeError"] = detectionError
    }
    if let queueRootPath = state.queueRootPath {
        payload["queueRoot"] = queueRootPath
        let metrics = queueMetrics(at: URL(fileURLWithPath: queueRootPath, isDirectory: true))
        payload["queueCount"] = metrics.count
        payload["objects"] = metrics.objectCount
        payload["queues"] = metrics.count
        if let freeBytes = metrics.freeBytes {
            payload["queueFreeBytes"] = freeBytes
        }
    } else {
        payload["queueCount"] = 1
        payload["objects"] = 0
        payload["queues"] = 1
    }
    let locationRecord = locationServiceRecord(from: state)
    payload["addresses"] = adminAddressesPayload(from: locationRecord)
    payload["connectivity"] = adminConnectivityPayload(from: locationRecord)
    if let presenceTimestamp = state.lastPresenceUpdate {
        payload["lastPresenceUpdate"] = iso8601String(presenceTimestamp)
    }
    if let error = state.lastReloadError {
        payload["message"] = error
    }
    return adminResponse(payload)
}

/// Builds a Location Service record from the current runtime snapshot.
/// - Parameter state: Runtime state used to populate the record.
/// - Returns: A `LocationServiceNodeRecord` mirroring the runtime connectivity data.
private func locationServiceRecord(from state: BoxServerRuntimeState) -> LocationServiceNodeRecord {
    let sinceTimestamp = millisecondsSince1970(state.onlineSince)
    let lastSeenDate = state.lastPresenceUpdate ?? Date()
    let portMappingActive = state.portMappingBackend != nil
    return LocationServiceNodeRecord.make(
        userUUID: state.userIdentifier,
        nodeUUID: state.nodeIdentifier,
        port: state.port,
        probedGlobalIPv6: state.globalIPv6Addresses,
        ipv6Error: state.ipv6DetectionError,
        portMappingEnabled: portMappingActive,
        portMappingOrigin: state.portMappingOrigin,
        since: sinceTimestamp,
        lastSeen: millisecondsSince1970(lastSeenDate)
    )
}

/// Converts Location Service addresses into an admin-channel friendly payload.
/// - Parameter record: Record providing the address list.
/// - Returns: Array of dictionaries ready for JSON serialisation.
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

/// Converts the Location Service connectivity snapshot into an admin payload.
/// - Parameter record: Record carrying the connectivity data.
/// - Returns: Dictionary ready for JSON serialisation.
private func adminConnectivityPayload(from record: LocationServiceNodeRecord) -> [String: Any] {
    var payload: [String: Any] = [
        "hasGlobalIPv6": record.connectivity.hasGlobalIPv6,
        "globalIPv6": record.connectivity.globalIPv6,
        "portMapping": [
            "enabled": record.connectivity.portMapping.enabled,
            "origin": record.connectivity.portMapping.origin
        ]
    ]
    if let error = record.connectivity.ipv6ProbeError {
        payload["ipv6ProbeError"] = error
    }
    return payload
}

/// Converts a full Location Service record into an admin payload dictionary.
/// - Parameter record: Record to serialise.
/// - Returns: Dictionary ready for JSON serialisation.
private func adminLocationRecordPayload(from record: LocationServiceNodeRecord) -> [String: Any] {
    var payload: [String: Any] = [
        "nodeUUID": record.nodeUUID.uuidString,
        "userUUID": record.userUUID.uuidString,
        "online": record.online,
        "since": Int(record.since),
        "lastSeen": Int(record.lastSeen),
        "addresses": adminAddressesPayload(from: record),
        "connectivity": adminConnectivityPayload(from: record)
    ]
    if let key = record.nodePublicKey {
        payload["nodePublicKey"] = key
    }
    if let tags = record.tags, !tags.isEmpty {
        payload["tags"] = tags
    }
    return payload
}

/// Converts a collection of Location Service records into a user-centric admin payload.
/// - Parameters:
///   - userUUID: Identifier of the user being described.
///   - records: Node records currently associated with the user.
/// - Returns: Dictionary ready for JSON serialisation.
private func adminLocationUserPayload(userUUID: UUID, records: [LocationServiceNodeRecord]) -> [String: Any] {
    let sortedRecords = records.sorted { $0.nodeUUID.uuidString < $1.nodeUUID.uuidString }
    return [
        "userUUID": userUUID.uuidString,
        "nodeCount": sortedRecords.count,
        "nodeUUIDs": sortedRecords.map { $0.nodeUUID.uuidString },
        "records": sortedRecords.map { adminLocationRecordPayload(from: $0) }
    ]
}

/// Converts `Date` instances into millisecond timestamps.
private func millisecondsSince1970(_ date: Date) -> UInt64 {
    UInt64((date.timeIntervalSince1970 * 1_000.0).rounded(.down))
}

/// Emits a structured log entry summarising the effective runtime configuration.
/// - Parameters:
///   - logger: Logger used for the entry.
///   - port: Effective UDP port.
///   - portOrigin: Origin of the port value (CLI/env/config/default).
///   - logLevel: Effective logging level.
///   - configurationPresent: Indicates whether a PLIST configuration was loaded.
///   - adminChannelEnabled: Whether the admin channel is active.
///   - transport: Optional transport indicator.
private func logStartupSummary(
    logger: Logger,
    port: UInt16,
    portOrigin: BoxRuntimeOptions.PortOrigin,
    logLevel: Logger.Level,
    logLevelOrigin: BoxRuntimeOptions.LogLevelOrigin,
    logTarget: BoxLogTarget,
    logTargetOrigin: BoxRuntimeOptions.LogTargetOrigin,
    configurationPresent: Bool,
    adminChannelEnabled: Bool,
    transport: String?,
    connectivity: ConnectivitySnapshot,
    portMappingRequested: Bool,
    portMappingOrigin: BoxRuntimeOptions.PortMappingOrigin
) {
    var metadata: Logger.Metadata = [
        "port": "\(port)",
        "portOrigin": "\(portOrigin)",
        "logLevel": "\(logLevel.rawValue)",
        "logLevelOrigin": "\(logLevelOrigin)",
        "logTarget": "\(logTargetDescription(logTarget))",
        "config": configurationPresent ? "present" : "absent",
        "admin": adminChannelEnabled ? "enabled" : "disabled",
        "transport": .string(transport ?? "clear"),
        "portMapping": .string(portMappingRequested ? "requested" : "disabled"),
        "portMappingOrigin": .string("\(portMappingOrigin)")
    ]

    if connectivity.hasGlobalIPv6 {
        metadata["ipv6"] = .array(connectivity.globalIPv6Addresses.map { Logger.MetadataValue.string($0) })
    } else if let error = connectivity.detectionErrorDescription {
        metadata["ipv6"] = .string("probe-error")
        metadata["ipv6Error"] = .string(error)
    } else {
        metadata["ipv6"] = .string("none")
    }

    logger.info(
        "server start",
        metadata: metadata
    )
}

private func probeConnectivity(logger: Logger) -> ConnectivitySnapshot {
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
            if isGlobalUnicastIPv6(ipv6Address), let host = numericHostString(for: addressPointer) {
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

#if !os(Windows)
private func numericHostString(for address: UnsafePointer<sockaddr>) -> String? {
    let length: socklen_t
    switch Int32(address.pointee.sa_family) {
    case AF_INET:
        length = socklen_t(MemoryLayout<sockaddr_in>.size)
    case AF_INET6:
        length = socklen_t(MemoryLayout<sockaddr_in6>.size)
    default:
        return nil
    }

    var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    let result = getnameinfo(address, length, &hostBuffer, socklen_t(hostBuffer.count), nil, 0, NI_NUMERICHOST)
    guard result == 0 else {
        return nil
    }
    let trimmedBytes = hostBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    var host = String(decoding: trimmedBytes, as: UTF8.self)
    if let percentIndex = host.firstIndex(of: "%") {
        host = String(host[..<percentIndex])
    }
    return host
}

private func isGlobalUnicastIPv6(_ address: in6_addr) -> Bool {
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
        if allZero {
            return false
        }

        var isLoopback = true
        for index in 0..<15 {
            if bytes[index] != 0 {
                isLoopback = false
                break
            }
        }
        if isLoopback && bytes[15] == 1 {
            return false
        }

        if bytes[0] == 0xff { return false }
        if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80 { return false }
        if (bytes[0] & 0xfe) == 0xfc { return false }

        return true
    }
}
#endif

private final class PortMappingCoordinator: @unchecked Sendable {
    struct MappingSnapshot: Sendable {
        let backend: String
        let externalPort: UInt16
        let gateway: String?
        let service: String?
        let lifetime: UInt32
        let refreshedAt: Date
    }

    private enum Backend: Sendable {
        case upnp(service: UPnPServiceDescription, internalClient: String)
        case natpmp(gateway: String)

        var identifier: String {
            switch self {
            case .upnp: return "upnp"
            case .natpmp: return "natpmp"
            }
        }

        var gateway: String? {
            switch self {
            case .upnp: return nil
            case .natpmp(let gateway): return gateway
            }
        }

        var serviceDescription: String? {
            switch self {
            case .upnp(let service, _): return service.serviceType
            case .natpmp: return nil
            }
        }
    }

    private struct MappingHandle: Sendable {
        let backend: Backend
        let externalPort: UInt16
        let lifetime: UInt32
    }

    private let logger: Logger
    private let port: UInt16
    private let origin: BoxRuntimeOptions.PortMappingOrigin
    private let leaseDuration: UInt32 = 3_600
    private var task: Task<Void, Never>?
    private let state = NIOLockedValueBox<MappingHandle?>(nil)
    private let onStateChange: @Sendable (MappingSnapshot?) -> Void

    init(
        logger: Logger,
        port: UInt16,
        origin: BoxRuntimeOptions.PortMappingOrigin,
        onStateChange: @escaping @Sendable (MappingSnapshot?) -> Void
    ) {
        self.logger = logger
        self.port = port
        self.origin = origin
        self.onStateChange = onStateChange
    }

    func start() {
#if os(Windows)
        logger.info("port mapping not available on Windows yet", metadata: ["origin": "\(origin)"])
#else
        guard task == nil else { return }
        logger.info(
            "port mapping requested",
            metadata: [
                "port": "\(port)",
                "origin": "\(origin)"
            ]
        )
        task = Task.detached { [weak self] in
            await self?.run()
        }
#endif
    }

    func stop() {
#if !os(Windows)
        task?.cancel()
        task = nil
#endif
        if let handle = state.withLockedValue({ $0 }) {
            Task.detached { [weak self] in
                await self?.removeMapping(handle)
            }
        } else {
            onStateChange(nil)
        }
        logger.debug("port mapping coordinator stopped")
    }

#if !os(Windows)
    private func run() async {
        do {
            guard let localAddress = try firstNonLoopbackIPv4Address() else {
                logger.info("port mapping skipped: no non-loopback IPv4 address detected")
                onStateChange(nil)
                return
            }
            try Task.checkCancellation()

            if let handle = await attemptUPnP(localAddress: localAddress) {
                await maintainMapping(initial: handle)
                return
            }

            if let handle = try attemptNATPMP() {
                await maintainMapping(initial: handle)
                return
            }

            logger.info("port mapping skipped: no supported gateway found")
            onStateChange(nil)
        } catch {
            if Task.isCancelled { return }
            logger.warning("port mapping aborted", metadata: ["error": .string("\(error)")])
            onStateChange(nil)
        }
    }

    private func maintainMapping(initial handle: MappingHandle) async {
        var currentHandle = handle
        publish(handle: currentHandle)
        defer {
            Task {
                await removeMapping(currentHandle)
            }
        }

        while !Task.isCancelled {
            let refreshSeconds = max(Int(currentHandle.lifetime / 2), 60)
            do {
                try await Task.sleep(nanoseconds: UInt64(refreshSeconds) * 1_000_000_000)
            } catch {
                if Task.isCancelled { return }
            }

            do {
                currentHandle = try await refreshMapping(currentHandle)
                publish(handle: currentHandle)
            } catch {
                if Task.isCancelled { return }
                logger.warning("port mapping refresh failed", metadata: ["error": .string("\(error)"), "backend": .string(currentHandle.backend.identifier)])
                return
            }
        }
    }

    private func publish(handle: MappingHandle) {
        let snapshot = MappingSnapshot(
            backend: handle.backend.identifier,
            externalPort: handle.externalPort,
            gateway: handle.backend.gateway,
            service: handle.backend.serviceDescription,
            lifetime: handle.lifetime,
            refreshedAt: Date()
        )
        state.withLockedValue { $0 = handle }
        onStateChange(snapshot)
    }

    private func refreshMapping(_ handle: MappingHandle) async throws -> MappingHandle {
        switch handle.backend {
        case .upnp(let service, let client):
            try await addPortMapping(service: service, internalClient: client)
            return MappingHandle(backend: handle.backend, externalPort: handle.externalPort, lifetime: handle.lifetime)
        case .natpmp(let gateway):
            let external = try performNATPMPMapping(gateway: gateway, lifetime: handle.lifetime)
            return MappingHandle(backend: .natpmp(gateway: gateway), externalPort: external, lifetime: handle.lifetime)
        }
    }

    private func attemptUPnP(localAddress: String) async -> MappingHandle? {
        do {
            guard let service = try await discoverService() else {
                logger.debug("UPnP gateway not discovered")
                return nil
            }
            try Task.checkCancellation()

            do {
                try await addPortMapping(service: service, internalClient: localAddress)
                logger.info(
                    "UPnP port mapping established",
                    metadata: [
                        "externalPort": "\(port)",
                        "internalClient": .string(localAddress),
                        "service": .string(service.serviceType)
                    ]
                )
                return MappingHandle(backend: .upnp(service: service, internalClient: localAddress), externalPort: port, lifetime: leaseDuration)
            } catch {
                if Task.isCancelled { return nil }
                logger.warning(
                    "failed to create UPnP port mapping",
                    metadata: ["error": .string("\(error)"), "service": .string(service.serviceType)]
                )
            }
        } catch {
            if Task.isCancelled { return nil }
            logger.warning("UPnP discovery failed", metadata: ["error": .string("\(error)")])
        }
        return nil
    }

    private func attemptNATPMP() throws -> MappingHandle? {
        guard let gateway = defaultGatewayIPv4() else {
            logger.debug("NAT-PMP gateway not detected")
            return nil
        }
        let externalPort = try performNATPMPMapping(gateway: gateway, lifetime: leaseDuration)
        logger.info(
            "NAT-PMP port mapping established",
            metadata: [
                "externalPort": "\(externalPort)",
                "gateway": .string(gateway)
            ]
        )
        return MappingHandle(backend: .natpmp(gateway: gateway), externalPort: externalPort, lifetime: leaseDuration)
    }

    private func discoverService() async throws -> UPnPServiceDescription? {
        guard let descriptionURL = try discoverDeviceDescriptionURL() else {
            return nil
        }
        try Task.checkCancellation()
        let data = try await fetchDeviceDescription(from: descriptionURL)
        try Task.checkCancellation()
        let services = try parseServices(from: data, baseURL: descriptionURL)
        return selectPreferredService(from: services)
    }

    private func addPortMapping(service: UPnPServiceDescription, internalClient: String) async throws {
        let arguments = [
            "NewRemoteHost": "",
            "NewExternalPort": "\(port)",
            "NewProtocol": "UDP",
            "NewInternalPort": "\(port)",
            "NewInternalClient": internalClient,
            "NewEnabled": "1",
            "NewPortMappingDescription": "boxd",
            "NewLeaseDuration": "\(leaseDuration)"
        ]
        _ = try await sendSOAPRequest(
            action: "AddPortMapping",
            arguments: arguments,
            service: service
        )
    }

    private func removeMapping(_ handle: MappingHandle) async {
        switch handle.backend {
        case .upnp(let service, _):
            let arguments = [
                "NewRemoteHost": "",
                "NewExternalPort": "\(handle.externalPort)",
                "NewProtocol": "UDP"
            ]
            do {
                _ = try await sendSOAPRequest(
                    action: "DeletePortMapping",
                    arguments: arguments,
                    service: service
                )
                logger.debug("UPnP port mapping removed", metadata: ["port": "\(handle.externalPort)"])
            } catch {
                logger.debug("unable to remove UPnP port mapping", metadata: ["error": .string("\(error)")])
            }
        case .natpmp(let gateway):
            do {
                try performNATPMPDeletion(gateway: gateway, externalPort: handle.externalPort)
                logger.debug("NAT-PMP port mapping removed", metadata: ["port": "\(handle.externalPort)"])
            } catch {
                logger.debug("unable to remove NAT-PMP port mapping", metadata: ["error": .string("\(error)")])
            }
        }
        state.withLockedValue { $0 = nil }
        onStateChange(nil)
    }

    private func discoverDeviceDescriptionURL() throws -> URL? {
        let responseData = try performSSDPDiscovery()
        guard let responseData else { return nil }
        let headers = PortMappingUtilities.parseSSDPResponse(responseData)
        guard let location = headers["location"], let url = URL(string: location) else {
            return nil
        }
        return url
    }

    private func fetchDeviceDescription(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw PortMappingError.httpError
        }
        return data
    }

    private func parseServices(from data: Data, baseURL: URL) throws -> [UPnPServiceDescription] {
        let parser = UPnPDeviceDescriptionParser(baseURL: baseURL)
        return try parser.parse(data: data)
    }

    private func selectPreferredService(from services: [UPnPServiceDescription]) -> UPnPServiceDescription? {
        let priorities = [
            "urn:schemas-upnp-org:service:WANIPConnection:2",
            "urn:schemas-upnp-org:service:WANIPConnection:1",
            "urn:schemas-upnp-org:service:WANPPPConnection:1"
        ]

        for target in priorities {
            if let match = services.first(where: { $0.serviceType == target }) {
                return match
            }
        }
        for service in services where service.serviceType.contains("WANIPConnection") || service.serviceType.contains("WANPPPConnection") {
            return service
        }
        return nil
    }

    private func sendSOAPRequest(
        action: String,
        arguments: [String: String],
        service: UPnPServiceDescription
    ) async throws -> Data {
        var request = URLRequest(url: service.controlURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(service.serviceType)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        if let host = service.controlURL.host {
            var header = host
            if let port = service.controlURL.port {
                header += ":\(port)"
            }
            request.setValue(header, forHTTPHeaderField: "Host")
        }

        let body = soapEnvelope(action: action, serviceType: service.serviceType, arguments: arguments)
        request.httpBody = body
        request.setValue("\(body.count)", forHTTPHeaderField: "Content-Length")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PortMappingError.httpError
        }
        guard (200...299).contains(http.statusCode) else {
            throw PortMappingError.soapFault(code: http.statusCode, payload: data)
        }
        return data
    }

    private func soapEnvelope(action: String, serviceType: String, arguments: [String: String]) -> Data {
        var argumentXML = ""
        for (key, value) in arguments {
            argumentXML += "<\(key)>\(PortMappingUtilities.escapeXML(value))</\(key)>"
        }
        let body = """
        <?xml version="1.0"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:\(action) xmlns:u="\(serviceType)">
              \(argumentXML)
            </u:\(action)>
          </s:Body>
        </s:Envelope>
        """
        return Data(body.utf8)
    }

    private func performSSDPDiscovery() throws -> Data? {
        let socketDescriptor = socket(AF_INET, Int32(SOCK_DGRAM), Int32(IPPROTO_UDP))
        guard socketDescriptor >= 0 else {
            throw PortMappingError.socket(errno)
        }
        defer { close(socketDescriptor) }

        var enable: Int32 = 1
        withUnsafeBytes(of: &enable) { buffer in
            _ = setsockopt(socketDescriptor, SOL_SOCKET, SO_REUSEADDR, buffer.baseAddress, socklen_t(buffer.count))
        }

        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        withUnsafeBytes(of: &timeout) { buffer in
            _ = setsockopt(socketDescriptor, SOL_SOCKET, SO_RCVTIMEO, buffer.baseAddress, socklen_t(buffer.count))
        }

        var multicastAddress = sockaddr_in()
        multicastAddress.sin_family = sa_family_t(AF_INET)
        multicastAddress.sin_port = in_port_t(UInt16(1900).bigEndian)
        multicastAddress.sin_addr = in_addr(s_addr: inet_addr("239.255.255.250"))
        let request = """
        M-SEARCH * HTTP/1.1\r
        HOST: 239.255.255.250:1900\r
        MAN: "ssdp:discover"\r
        MX: 2\r
        ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r
        USER-AGENT: Box/0.1 UPnP/1.1\r
        \r
        """
        try request.withCString { pointer in
            let length = strlen(pointer)
            let sent = withUnsafePointer(to: &multicastAddress) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(socketDescriptor, pointer, length, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if sent < 0 {
                throw PortMappingError.socket(errno)
            }
        }

        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = recv(socketDescriptor, &buffer, buffer.count, 0)
        if bytesRead <= 0 {
            return nil
        }
        return Data(buffer[0..<bytesRead])
    }

    private func firstNonLoopbackIPv4Address() throws -> String? {
        var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPointer) == 0, let basePointer = ifaddrPointer else {
            let message = String(cString: strerror(errno))
            throw PortMappingError.network(message)
        }
        defer { freeifaddrs(basePointer) }

        var cursor = basePointer
        while true {
            let flags = Int32(bitPattern: UInt32(cursor.pointee.ifa_flags))
            guard (flags & Int32(IFF_UP)) != 0 else {
                if let next = cursor.pointee.ifa_next { cursor = next; continue } else { break }
            }
            guard (flags & Int32(IFF_LOOPBACK)) == 0 else {
                if let next = cursor.pointee.ifa_next { cursor = next; continue } else { break }
            }
            guard let addr = cursor.pointee.ifa_addr else {
                if let next = cursor.pointee.ifa_next { cursor = next; continue } else { break }
            }
            if Int32(addr.pointee.sa_family) == AF_INET {
                if let host = numericHostString(for: UnsafePointer(addr)) {
                    return host
                }
            }
            if let next = cursor.pointee.ifa_next {
                cursor = next
            } else {
                break
            }
        }
        return nil
    }

    private func performNATPMPMapping(gateway: String, lifetime: UInt32) throws -> UInt16 {
        let socketDescriptor = socket(AF_INET, Int32(SOCK_DGRAM), Int32(IPPROTO_UDP))
        guard socketDescriptor >= 0 else {
            throw PortMappingError.socket(errno)
        }
        defer { close(socketDescriptor) }

        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        withUnsafeBytes(of: &timeout) { buffer in
            _ = setsockopt(socketDescriptor, SOL_SOCKET, SO_RCVTIMEO, buffer.baseAddress, socklen_t(buffer.count))
        }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(5351).bigEndian)
        guard inet_pton(AF_INET, gateway, &addr.sin_addr) == 1 else {
            throw PortMappingError.network("invalid-gateway-address")
        }

        var request = [UInt8](repeating: 0, count: 12)
        request[0] = 0
        request[1] = 1
        request[4] = UInt8(port >> 8)
        request[5] = UInt8(port & 0xff)
        request[6] = UInt8(port >> 8)
        request[7] = UInt8(port & 0xff)
        request[8] = UInt8((lifetime >> 24) & 0xff)
        request[9] = UInt8((lifetime >> 16) & 0xff)
        request[10] = UInt8((lifetime >> 8) & 0xff)
        request[11] = UInt8(lifetime & 0xff)

        let sent = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(socketDescriptor, request, request.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if sent < 0 {
            throw PortMappingError.socket(errno)
        }

        var buffer = [UInt8](repeating: 0, count: 32)
        let bytesRead = recv(socketDescriptor, &buffer, buffer.count, 0)
        guard bytesRead >= 16 else {
            throw PortMappingError.natpmp("short-response")
        }
        guard buffer[0] == 0 else {
            throw PortMappingError.natpmp("unsupported-version")
        }
        guard buffer[1] == 0x81 else {
            throw PortMappingError.natpmp("unexpected-opcode")
        }
        let resultCode = (UInt16(buffer[2]) << 8) | UInt16(buffer[3])
        guard resultCode == 0 else {
            throw PortMappingError.natpmp("result-\(resultCode)")
        }
        let externalPort = (UInt16(buffer[8]) << 8) | UInt16(buffer[9])
        return externalPort
    }

    private func performNATPMPDeletion(gateway: String, externalPort: UInt16) throws {
        let socketDescriptor = socket(AF_INET, Int32(SOCK_DGRAM), Int32(IPPROTO_UDP))
        guard socketDescriptor >= 0 else {
            throw PortMappingError.socket(errno)
        }
        defer { close(socketDescriptor) }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        withUnsafeBytes(of: &timeout) { buffer in
            _ = setsockopt(socketDescriptor, SOL_SOCKET, SO_RCVTIMEO, buffer.baseAddress, socklen_t(buffer.count))
        }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(5351).bigEndian)
        guard inet_pton(AF_INET, gateway, &addr.sin_addr) == 1 else {
            throw PortMappingError.network("invalid-gateway-address")
        }

        var request = [UInt8](repeating: 0, count: 12)
        request[0] = 0
        request[1] = 1
        request[4] = UInt8(port >> 8)
        request[5] = UInt8(port & 0xff)
        request[6] = UInt8(externalPort >> 8)
        request[7] = UInt8(externalPort & 0xff)

        let sent = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(socketDescriptor, request, request.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if sent < 0 {
            throw PortMappingError.socket(errno)
        }
    }

    private func defaultGatewayIPv4() -> String? {
#if os(Linux)
        guard let contents = try? String(contentsOfFile: "/proc/net/route") else { return nil }
        return PortMappingUtilities.defaultGateway(fromProcNetRoute: contents)
#elseif canImport(SystemConfiguration)
        guard let store = SCDynamicStoreCreate(nil, "box.portmapping" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let router = value["Router"] as? String else {
            return nil
        }
        return router
#else
        return nil
#endif
    }
#endif
}

#if !os(Windows)
internal struct UPnPServiceDescription: Sendable, Equatable {
    let serviceType: String
    let controlURL: URL
}

private enum PortMappingError: Error, CustomStringConvertible {
    case socket(Int32)
    case httpError
    case soapFault(code: Int, payload: Data)
    case network(String)
    case natpmp(String)

    var description: String {
        switch self {
        case .socket(let code):
            return "socket-error(\(code))"
        case .httpError:
            return "http-error"
        case .soapFault(let code, _):
            return "soap-fault(\(code))"
        case .network(let message):
            return "network-error(\(message))"
        case .natpmp(let message):
            return "natpmp-error(\(message))"
        }
    }
}

internal enum PortMappingUtilities {
    static func parseSSDPResponse(_ data: Data) -> [String: String] {
        guard let response = String(data: data, encoding: .utf8) else { return [:] }
        let normalized = response.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n")
        var headers: [String: String] = [:]
        for line in lines {
            if let separatorIndex = line.firstIndex(of: ":") {
                let name = line[..<separatorIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let value = line[line.index(after: separatorIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
                headers[name] = value
            }
        }
        return headers
    }

    static func escapeXML(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "&": result.append("&amp;")
            case "<": result.append("&lt;")
            case ">": result.append("&gt;")
            case "\"": result.append("&quot;")
            case "'": result.append("&apos;")
            default: result.append(character)
            }
        }
        return result
    }

    static func decodeLittleEndianIPv4(_ hex: String) -> String? {
        guard hex.count == 8, let value = UInt32(hex, radix: 16) else { return nil }
        let byte0 = UInt8(value & 0xFF)
        let byte1 = UInt8((value >> 8) & 0xFF)
        let byte2 = UInt8((value >> 16) & 0xFF)
        let byte3 = UInt8((value >> 24) & 0xFF)
        return "\(byte0).\(byte1).\(byte2).\(byte3)"
    }

    static func defaultGateway(fromProcNetRoute contents: String) -> String? {
        let lines = contents.split(whereSeparator: \.isNewline)
        guard lines.count > 1 else { return nil }
        for line in lines.dropFirst() {
            let columns = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard columns.count >= 3 else { continue }
            let destinationHex = String(columns[1])
            let gatewayHex = String(columns[2])
            if destinationHex.caseInsensitiveCompare("00000000") == .orderedSame {
                if let address = decodeLittleEndianIPv4(gatewayHex) {
                    return address
                }
            }
        }
        return nil
    }
}

internal final class UPnPDeviceDescriptionParser: NSObject, XMLParserDelegate {
    private let baseURL: URL
    private var services: [UPnPServiceDescription] = []
    private var currentServiceType: String?
    private var currentControlURL: String?
    private var currentElement: String?
    private var accumulator = ""

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    func parse(data: Data) throws -> [UPnPServiceDescription] {
        services = []
        let parser = XMLParser(data: data)
        parser.delegate = self
        if parser.parse() {
            return services
        }
        if let error = parser.parserError {
            throw error
        }
        return services
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
        accumulator.removeAll(keepingCapacity: true)
        if elementName == "service" {
            currentServiceType = nil
            currentControlURL = nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        accumulator.append(string)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = accumulator.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "serviceType":
            currentServiceType = value
        case "controlURL":
            currentControlURL = value
        case "service":
            if let serviceType = currentServiceType, let urlString = currentControlURL,
               let resolvedURL = URL(string: urlString, relativeTo: baseURL)?.absoluteURL {
                services.append(UPnPServiceDescription(serviceType: serviceType, controlURL: resolvedURL))
            }
            currentServiceType = nil
            currentControlURL = nil
        default:
            break
        }
        currentElement = nil
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

/// Requests the admin channel to begin shutting down.
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

/// Waits for the admin channel to terminate.
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

/// Formats a date using ISO8601 representation (UTC).
/// - Parameter date: Date to format.
/// - Returns: ISO8601 string.
private func iso8601String(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    return formatter.string(from: date)
}

private func adminResponse(_ payload: [String: Any]) -> String {
    if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
       let string = String(data: data, encoding: .utf8) {
        return string
    }
    return "{\"status\":\"error\",\"message\":\"encoding-failure\"}"
}
