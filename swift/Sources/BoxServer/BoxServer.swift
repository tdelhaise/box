import BoxCore
import Foundation
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
        let configuration: BoxServerConfiguration?
        do {
            configuration = try BoxServerConfiguration.loadDefault(explicitPath: options.configurationPath)
        } catch {
            if let configURL = configurationURL {
                throw BoxRuntimeError.configurationLoadFailed(configURL)
            } else {
                throw error
            }
        }

        if portOrigin == .default, let configPort = configuration?.port {
            effectivePort = configPort
            portOrigin = .configuration
        }

        var effectiveLogLevel = options.logLevel
        var logLevelOrigin = options.logLevelOrigin
        if logLevelOrigin == .default, let configLogLevel = configuration?.logLevel {
            effectiveLogLevel = configLogLevel
            logLevelOrigin = .configuration
        }
        logger.logLevel = effectiveLogLevel
        BoxLogging.update(level: effectiveLogLevel)

        var effectiveLogTarget = options.logTarget
        var logTargetOrigin = options.logTargetOrigin
        if logTargetOrigin == .default, let configTarget = configuration?.logTarget {
            if let parsedTarget = BoxLogTarget.parse(configTarget) {
                effectiveLogTarget = parsedTarget
                logTargetOrigin = .configuration
            } else {
                logger.warning("invalid log target in configuration", metadata: ["value": "\(configTarget)"])
            }
        }
        BoxLogging.update(target: effectiveLogTarget)

        var adminChannelEnabled = options.adminChannelEnabled
        if let configAdmin = configuration?.adminChannelEnabled {
            adminChannelEnabled = configAdmin
        }

        let selectedTransport = configuration?.transportGeneral

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
            queueRootPath: queueRoot.path,
            reloadCount: 0,
            lastReloadTimestamp: nil,
            lastReloadStatus: "never",
            lastReloadError: nil
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
            configurationPresent: configuration != nil,
            adminChannelEnabled: adminChannelEnabled,
            transport: selectedTransport
        )

        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        let store = BoxServerStore()
        let statusProvider: @Sendable () -> String = {
            let snapshot = runtimeStateBox.withLockedValue { $0 }
            let currentTarget = BoxLogging.currentTarget()
            return renderStatus(state: snapshot, store: store, logTarget: currentTarget)
        }
        let logTargetUpdater: @Sendable (String) -> String = { candidate in
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
        let reloadConfigurationHandler: @Sendable (String?) -> String = { path in
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
                guard let loaded = try BoxServerConfiguration.load(from: url) else {
                    let timestamp = Date()
                    runtimeStateBox.withLockedValue { state in
                        state.reloadCount += 1
                        state.lastReloadTimestamp = timestamp
                        state.lastReloadStatus = "error"
                        state.lastReloadError = "configuration-not-found"
                    }
                    return adminResponse(["status": "error", "message": "configuration-not-found", "path": configPath])
                }

                let timestamp = Date()
                let targetAdjustment = runtimeStateBox.withLockedValue { state -> BoxLogTarget? in
                    state.reloadCount += 1
                    state.lastReloadTimestamp = timestamp
                    state.configurationPath = configPath
                    state.configuration = loaded
                    state.lastReloadStatus = "ok"
                    state.lastReloadError = nil

                    var targetCandidate: BoxLogTarget?

                    if state.logTargetOrigin != .cliFlag {
                        if let targetString = loaded.logTarget, let parsed = BoxLogTarget.parse(targetString) {
                            if state.logTarget != parsed {
                                targetCandidate = parsed
                            }
                            state.logTarget = parsed
                            state.logTargetOrigin = .configuration
                        } else if loaded.logTarget != nil {
                            state.lastReloadStatus = "partial"
                            state.lastReloadError = "invalid-log-target"
                        }
                    }

                    if state.logLevelOrigin != .cliFlag {
                        if let level = loaded.logLevel {
                            state.logLevel = level
                            state.logLevelOrigin = .configuration
                        } else if state.logLevelOrigin == .configuration {
                            state.logLevelOrigin = .default
                            let defaultLevel: Logger.Level = .info
                            state.logLevel = defaultLevel
                        }
                    }

                    if let transport = loaded.transportGeneral {
                        state.transport = transport
                    }
                    if let adminEnabled = loaded.adminChannelEnabled {
                        state.adminChannelEnabled = adminEnabled
                    }

                    return targetCandidate
                }

                if let newTarget = targetAdjustment {
                    BoxLogging.update(target: newTarget)
                }

                let snapshot = runtimeStateBox.withLockedValue { $0 }
                BoxLogging.update(level: snapshot.logLevel)
                var response: [String: Any] = [
                    "status": snapshot.lastReloadStatus,
                    "path": configPath,
                    "logLevel": snapshot.logLevel.rawValue,
                    "logLevelOrigin": "\(snapshot.logLevelOrigin)",
                    "logTarget": logTargetDescription(snapshot.logTarget),
                    "logTargetOrigin": "\(snapshot.logTargetOrigin)",
                    "reloadCount": snapshot.reloadCount
                ]
                if let nodeUUID = snapshot.configuration?.nodeUUID.uuidString {
                    response["nodeUUID"] = nodeUUID
                }
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
        let statsProvider: @Sendable () -> String = {
            let snapshot = runtimeStateBox.withLockedValue { $0 }
            let currentTarget = BoxLogging.currentTarget()
            return renderStats(state: snapshot, store: store, logTarget: currentTarget)
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
                    statsProvider: statsProvider
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

        let bootstrap = DatagramBootstrap(group: eventLoopGroup)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandler(BoxServerHandler(logger: pipelineLogger, allocator: channel.allocator, store: store))
            }

        do {
            let channel = try await bootstrap.bind(host: options.address, port: Int(effectivePort)).get()
            let channelBox = UncheckedSendableBox(channel)
            logger.info("server listening", metadata: ["address": "\(options.address)", "port": "\(effectivePort)"])

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

            logger.info("server stopped")
            try await eventLoopGroup.shutdownGracefully()
        } catch {
            logger.error("server failed: \(error)")
            if let handle = adminChannelBox.withLockedValue({ $0 }) {
                initiateAdminChannelShutdown(handle)
                await waitForAdminChannelShutdown(handle)
            }
            try? await eventLoopGroup.shutdownGracefully()
            throw error
        }
    }
}

/// In-memory stored object for demo PUT/GET flows.
private struct BoxStoredObject: Sendable {
    /// Content type associated with the stored payload.
    var contentType: String
    /// Stored payload bytes.
    var data: [UInt8]
}

/// Thread-safe store shared between datagram pipeline and admin channel queries.
private final class BoxServerStore: @unchecked Sendable {
    private let storage = NIOLockedValueBox<[String: BoxStoredObject]>([:])

    /// Saves or replaces an object for the supplied queue path.
    func set(object: BoxStoredObject, for queuePath: String) {
        storage.withLockedValue { storage in
            storage[queuePath] = object
        }
    }

    /// Retrieves the stored object if present.
    func get(queuePath: String) -> BoxStoredObject? {
        storage.withLockedValue { $0[queuePath] }
    }

    /// Counts the number of stored objects.
    func count() -> Int {
        storage.withLockedValue { $0.count }
    }
}

/// Captures mutable runtime state exposed over the admin channel and used for reload decisions.
private struct BoxServerRuntimeState: Sendable {
    var configurationPath: String?
    var configuration: BoxServerConfiguration?
    var logLevel: Logger.Level
    var logLevelOrigin: BoxRuntimeOptions.LogLevelOrigin
    var logTarget: BoxLogTarget
    var logTargetOrigin: BoxRuntimeOptions.LogTargetOrigin
    var adminChannelEnabled: Bool
    var port: UInt16
    var portOrigin: BoxRuntimeOptions.PortOrigin
    var transport: String?
    var queueRootPath: String?
    var reloadCount: Int
    var lastReloadTimestamp: Date?
    var lastReloadStatus: String
    var lastReloadError: String?
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

    init(logger: Logger, allocator: ByteBufferAllocator, store: BoxServerStore) {
        self.logger = logger
        self.allocator = allocator
        self.store = store
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
        default:
            let statusPayload = BoxCodec.encodeStatusPayload(
                status: .badRequest,
                message: "unknown-command",
                allocator: allocator
            )
            send(frame: BoxCodec.Frame(command: .status, requestId: frame.requestId + 1, payload: statusPayload), to: remote, context: context)
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
            send(frame: BoxCodec.Frame(command: .status, requestId: frame.requestId + 1, payload: statusPayload), to: remote, context: context)
            return
        }
        let responsePayload = try BoxCodec.encodeHelloPayload(status: .ok, versions: [1], allocator: allocator)
        send(frame: BoxCodec.Frame(command: .hello, requestId: frame.requestId + 1, payload: responsePayload), to: remote, context: context)
    }

    private func respondToStatus(frame: BoxCodec.Frame, remote: SocketAddress, context: ChannelHandlerContext) throws {
        var payload = frame.payload
        let status = try BoxCodec.decodeStatusPayload(from: &payload)
        logger.debug("STATUS received", metadata: ["status": "\(status.status)", "message": "\(status.message)"])
        let pongPayload = BoxCodec.encodeStatusPayload(status: .ok, message: "pong", allocator: allocator)
        send(frame: BoxCodec.Frame(command: .status, requestId: frame.requestId + 1, payload: pongPayload), to: remote, context: context)
    }

    private func handlePut(payload: inout ByteBuffer, frame: BoxCodec.Frame, remote: SocketAddress, context: ChannelHandlerContext) throws {
        let putPayload = try BoxCodec.decodePutPayload(from: &payload)
        store.set(object: BoxStoredObject(contentType: putPayload.contentType, data: putPayload.data), for: putPayload.queuePath)
        logger.info("stored object", metadata: ["queue": "\(putPayload.queuePath)", "bytes": "\(putPayload.data.count)"])
        let statusPayload = BoxCodec.encodeStatusPayload(status: .ok, message: "stored", allocator: allocator)
        send(frame: BoxCodec.Frame(command: .status, requestId: frame.requestId + 1, payload: statusPayload), to: remote, context: context)
    }

    private func handleGet(payload: inout ByteBuffer, frame: BoxCodec.Frame, remote: SocketAddress, context: ChannelHandlerContext) throws {
        let getPayload = try BoxCodec.decodeGetPayload(from: &payload)
        if let object = store.get(queuePath: getPayload.queuePath) {
            let responsePayload = BoxCodec.encodePutPayload(
                BoxCodec.PutPayload(queuePath: getPayload.queuePath, contentType: object.contentType, data: object.data),
                allocator: allocator
            )
            send(frame: BoxCodec.Frame(command: .put, requestId: frame.requestId + 1, payload: responsePayload), to: remote, context: context)
        } else {
            let statusPayload = BoxCodec.encodeStatusPayload(status: .badRequest, message: "not-found", allocator: allocator)
            send(frame: BoxCodec.Frame(command: .status, requestId: frame.requestId + 1, payload: statusPayload), to: remote, context: context)
        }
    }

    private func send(frame: BoxCodec.Frame, to remote: SocketAddress, context: ChannelHandlerContext) {
        let datagram = BoxCodec.encodeFrame(frame, allocator: allocator)
        let envelope = AddressedEnvelope(remoteAddress: remote, data: datagram)
        context.writeAndFlush(wrapOutboundOut(envelope), promise: nil)
    }
}

extension BoxServerHandler: @unchecked Sendable {}

/// Dispatches admin commands to the appropriate runtime closures.
struct BoxAdminCommandDispatcher: Sendable {
    private let statusProvider: @Sendable () -> String
    private let logTargetUpdater: @Sendable (String) -> String
    private let reloadConfiguration: @Sendable (String?) -> String
    private let statsProvider: @Sendable () -> String

    init(
        statusProvider: @escaping @Sendable () -> String,
        logTargetUpdater: @escaping @Sendable (String) -> String,
        reloadConfiguration: @escaping @Sendable (String?) -> String,
        statsProvider: @escaping @Sendable () -> String
    ) {
        self.statusProvider = statusProvider
        self.logTargetUpdater = logTargetUpdater
        self.reloadConfiguration = reloadConfiguration
        self.statsProvider = statsProvider
    }

    /// Processes a raw admin command string and returns the JSON response payload.
    /// - Parameter rawValue: Command string as received on the transport.
    /// - Returns: JSON response (without trailing newline).
    func process(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return adminResponse(["status": "error", "message": "empty-command"])
        }
        let command = parse(trimmed)
        switch command {
        case .status:
            return statusProvider()
        case .ping:
            return adminResponse(["status": "ok", "message": "pong"])
        case .logTarget(let target):
            return logTargetUpdater(target)
        case .reloadConfig(let path):
            return reloadConfiguration(path)
        case .stats:
            return statsProvider()
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

    convenience init(
        logger: Logger,
        statusProvider: @escaping @Sendable () -> String,
        logTargetUpdater: @escaping @Sendable (String) -> String,
        reloadConfiguration: @escaping @Sendable (String?) -> String,
        statsProvider: @escaping @Sendable () -> String
    ) {
        let dispatcher = BoxAdminCommandDispatcher(
            statusProvider: statusProvider,
            logTargetUpdater: logTargetUpdater,
            reloadConfiguration: reloadConfiguration,
            statsProvider: statsProvider
        )
        self.init(logger: logger, dispatcher: dispatcher)
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
        let response = dispatcher.process(command)
        write(response: response, context: context)
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
            pipePath.withCString(encodedAs: UTF16.self) { pointer in
                self.runLoop(pipeName: pointer)
            }
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

    private func runLoop(pipeName: UnsafePointer<WCHAR>) {
        let bufferSize: DWORD = 4096
        if securityAttributes == nil {
            logger.warning("admin pipe security: using default ACL (Windows descriptor creation failed)")
        }
        while !shouldStop.withLockedValue({ $0 }) {
            let handle = CreateNamedPipeW(
                pipeName,
                DWORD(PIPE_ACCESS_DUPLEX),
                DWORD(PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT),
                DWORD(1),
                bufferSize,
                bufferSize,
                DWORD(0),
                securityAttributes
            )

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
            let responsePayload = dispatcher.process(command)
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
    guard let boxDirectory = BoxPaths.boxDirectory(), let runDirectory = BoxPaths.runDirectory() else {
        logger.warning("unable to resolve ~/.box directories")
        return
    }
    try createDirectoryIfNeeded(at: boxDirectory)
    try createDirectoryIfNeeded(at: runDirectory)
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
    var freeBytes: UInt64?
}

/// Computes the number of queues (directories) and free disk space under the queue root.
private func queueMetrics(at root: URL) -> QueueMetrics {
    let fileManager = FileManager.default
    var queueCount = 0

    if let contents = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
        queueCount = contents.reduce(0) { partialResult, url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? partialResult + 1 : partialResult
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
    return QueueMetrics(count: queueCount, freeBytes: freeBytes)
}

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
    statusProvider: @escaping @Sendable () -> String,
    logTargetUpdater: @escaping @Sendable (String) -> String,
    reloadConfiguration: @escaping @Sendable (String?) -> String,
    statsProvider: @escaping @Sendable () -> String
) async throws -> BoxAdminChannelHandle {
    let dispatcher = BoxAdminCommandDispatcher(
        statusProvider: statusProvider,
        logTargetUpdater: logTargetUpdater,
        reloadConfiguration: reloadConfiguration,
        statsProvider: statsProvider
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
            let isMissingFile = nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileNoSuchFileError
            if !isMissingFile {
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
private func renderStatus(state: BoxServerRuntimeState, store: BoxServerStore, logTarget: BoxLogTarget) -> String {
    var payload: [String: Any] = [
        "status": "ok",
        "port": Int(state.port),
        "portOrigin": "\(state.portOrigin)",
        "objects": store.count(),
        "logLevel": state.logLevel.rawValue,
        "logLevelOrigin": "\(state.logLevelOrigin)",
        "logTarget": logTargetDescription(logTarget),
        "logTargetOrigin": "\(state.logTargetOrigin)",
        "adminChannel": state.adminChannelEnabled ? "enabled" : "disabled",
        "transport": state.transport ?? "clear",
        "reloadCount": state.reloadCount
    ]
    if let path = state.configurationPath {
        payload["configPath"] = path
    }
    if let nodeUUID = state.configuration?.nodeUUID.uuidString {
        payload["nodeUUID"] = nodeUUID
    }
    if let queueRootPath = state.queueRootPath {
        payload["queueRoot"] = queueRootPath
        let metrics = queueMetrics(at: URL(fileURLWithPath: queueRootPath, isDirectory: true))
        payload["queueCount"] = metrics.count
        if let freeBytes = metrics.freeBytes {
            payload["queueFreeBytes"] = freeBytes
        }
    } else {
        payload["queueCount"] = 1
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
private func renderStats(state: BoxServerRuntimeState, store: BoxServerStore, logTarget: BoxLogTarget) -> String {
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
        "queues": store.count(),
        "reloadCount": state.reloadCount
    ]
    if let path = state.configurationPath {
        payload["configPath"] = path
    }
    if let lastReload = state.lastReloadTimestamp {
        payload["lastReload"] = iso8601String(lastReload)
    }
    if let nodeUUID = state.configuration?.nodeUUID.uuidString {
        payload["nodeUUID"] = nodeUUID
    }
    if let queueRootPath = state.queueRootPath {
        payload["queueRoot"] = queueRootPath
        let metrics = queueMetrics(at: URL(fileURLWithPath: queueRootPath, isDirectory: true))
        payload["queueCount"] = metrics.count
        if let freeBytes = metrics.freeBytes {
            payload["queueFreeBytes"] = freeBytes
        }
    } else {
        payload["queueCount"] = 1
    }
    if let error = state.lastReloadError {
        payload["message"] = error
    }
    return adminResponse(payload)
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
    transport: String?
) {
    logger.info(
        "server start",
        metadata: [
            "port": "\(port)",
            "portOrigin": "\(portOrigin)",
            "logLevel": "\(logLevel.rawValue)",
            "logLevelOrigin": "\(logLevelOrigin)",
            "logTarget": "\(logTargetDescription(logTarget))",
            "config": configurationPresent ? "present" : "absent",
            "admin": adminChannelEnabled ? "enabled" : "disabled",
            "transport": .string(transport ?? "clear")
        ]
    )
}

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
