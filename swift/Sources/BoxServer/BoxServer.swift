import BoxCore
import Foundation
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

#if os(Linux)
import Glibc
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
        if let homeDirectory {
            try ensureBoxDirectories(home: homeDirectory, logger: logger)
        } else {
            logger.warning("HOME not set; configuration and admin channel features may be unavailable")
        }

        var effectivePort = options.port
        var portOrigin = options.portOrigin
        if portOrigin == .default,
           let envValue = ProcessInfo.processInfo.environment["BOXD_PORT"],
           let parsed = UInt16(envValue) {
            effectivePort = parsed
            portOrigin = .environment
        }

        let configuration: BoxServerConfiguration?
        do {
            configuration = try BoxServerConfiguration.loadDefault(explicitPath: options.configurationPath)
        } catch {
            if let configURL = BoxPaths.serverConfigurationURL(explicitPath: options.configurationPath) {
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
        let statusPort = effectivePort
        let statusTransport = selectedTransport
        let statusLogLevel = logger.logLevel
        let statusProvider: @Sendable () -> String = {
            var snapshotLogger = Logging.Logger(label: "box.server.status")
            snapshotLogger.logLevel = statusLogLevel
            let currentTarget = BoxLogging.currentTarget()
            return renderStatus(port: statusPort, store: store, logger: snapshotLogger, transport: statusTransport, logTarget: currentTarget)
        }
        let logTargetUpdater: @Sendable (String) -> String = { candidate in
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = BoxLogTarget.parse(trimmed) else {
                return adminResponse(["status": "error", "message": "invalid-log-target"])
            }
            BoxLogging.update(target: parsed)
            return adminResponse(["status": "ok", "logTarget": logTargetDescription(parsed)])
        }

        let adminSocketPath = adminChannelEnabled ? BoxPaths.adminSocketPath() : nil
        let adminChannelBox = NIOLockedValueBox<Channel?>(nil)
        if let adminSocketPath {
            do {
                let channel = try await startAdminChannel(
                    on: eventLoopGroup,
                    socketPath: adminSocketPath,
                    logger: logger,
                    statusProvider: statusProvider,
                    logTargetUpdater: logTargetUpdater
                )
                adminChannelBox.withLockedValue { $0 = channel }
                logger.info("admin channel ready", metadata: ["socket": "\(adminSocketPath)"])
            } catch {
                logger.warning("unable to start admin channel", metadata: ["error": "\(error)"])
            }
        }

        defer {
            if let adminSocketPath {
                try? FileManager.default.removeItem(atPath: adminSocketPath)
            }
        }

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
                if let channel = adminChannelBox.withLockedValue({ $0 }) {
                    channel.close(promise: nil)
                }
            }

            if let channel = adminChannelBox.withLockedValue({ $0 }) {
                channel.close(promise: nil)
                try? await channel.closeFuture.get()
            }

            logger.info("server stopped")
            try await eventLoopGroup.shutdownGracefully()
        } catch {
            logger.error("server failed", metadata: ["error": "\(error)"])
            if let channel = adminChannelBox.withLockedValue({ $0 }) {
                channel.close(promise: nil)
                try? await channel.closeFuture.get()
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

/// Handler responding to admin channel requests (currently supports the `status` command).
private final class BoxAdminChannelHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let logger: Logger
    private let statusProvider: () -> String
    private let logTargetUpdater: (String) -> String

    init(logger: Logger, statusProvider: @escaping () -> String, logTargetUpdater: @escaping (String) -> String) {
        self.logger = logger
        self.statusProvider = statusProvider
        self.logTargetUpdater = logTargetUpdater
    }

    func channelActive(context: ChannelHandlerContext) {
        logger.debug("admin connection accepted")
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let command = buffer.readString(length: buffer.readableBytes)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else {
            context.close(promise: nil)
            return
        }

        let response: String
        if command == "status" {
            response = statusProvider()
        } else if command == "ping" {
            response = adminResponse(["status": "ok", "message": "pong"])
        } else if command.hasPrefix("log-target") {
            let targetString = command.dropFirst("log-target".count).trimmingCharacters(in: .whitespaces)
            guard !targetString.isEmpty else {
                response = adminResponse(["status": "error", "message": "missing-log-target"])
                write(response: response, context: context)
                return
            }
            response = logTargetUpdater(String(targetString))
        } else {
            response = adminResponse(["status": "error", "message": "unknown-command"])
        }

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
    if !exists {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: NSNumber(value: Int(S_IRWXU))])
    }
    chmod(url.path, S_IRWXU)
}

/// Binds the admin channel on the provided UNIX domain socket path.
/// - Parameters:
///   - eventLoopGroup: Event loop group used for the server bootstrap.
///   - socketPath: Filesystem path of the admin socket.
///   - logger: Logger used for diagnostics.
///   - statusProvider: Closure producing the JSON payload returned for `status`.
/// - Returns: The bound channel ready to accept admin connections.
private func startAdminChannel(
    on eventLoopGroup: EventLoopGroup,
    socketPath: String,
    logger: Logger,
    statusProvider: @escaping @Sendable () -> String,
    logTargetUpdater: @escaping @Sendable (String) -> String
) async throws -> Channel {
    if FileManager.default.fileExists(atPath: socketPath) {
        try FileManager.default.removeItem(atPath: socketPath)
    }

    let bootstrap = ServerBootstrap(group: eventLoopGroup)
        .serverChannelOption(ChannelOptions.backlog, value: 4)
        .childChannelInitializer { channel in
            channel.pipeline.addHandler(BoxAdminChannelHandler(logger: logger, statusProvider: statusProvider, logTargetUpdater: logTargetUpdater))
        }

    let channel = try await bootstrap.bind(unixDomainSocketPath: socketPath).get()
    chmod(socketPath, S_IRUSR | S_IWUSR)
    return channel
}

/// Builds a JSON status payload for the admin channel.
/// - Parameters:
///   - port: Effective UDP port used by the server.
///   - store: Shared object store (used to expose queue count).
///   - logger: Logger providing the current log level.
///   - transport: Optional transport description.
/// - Returns: A JSON string summarising the current server state.
private func renderStatus(port: UInt16, store: BoxServerStore, logger: Logger, transport: String?, logTarget: BoxLogTarget) -> String {
    let payload: [String: Any] = [
        "status": "ok",
        "port": Int(port),
        "objects": store.count(),
        "logLevel": logger.logLevel.rawValue,
        "transport": transport ?? "clear",
        "logTarget": logTargetDescription(logTarget)
    ]
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

private func adminResponse(_ payload: [String: Any]) -> String {
    if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
       let string = String(data: data, encoding: .utf8) {
        return string
    }
    return "{\"status\":\"error\",\"message\":\"encoding-failure\"}"
}
