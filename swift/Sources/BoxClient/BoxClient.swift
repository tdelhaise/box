import BoxCore
import Foundation
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

public enum BoxClientError: Error {
    case invalidAddress(String, UInt16)
    case timeout(TimeAmount)
    case noTargets
    case remoteRejected(status: BoxCodec.Status, message: String)
    case missingPingResponse
    case invalidAction
}

extension BoxClientError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidAddress(host, port):
            return "unable to resolve remote address \(host):\(port)"
        case let .timeout(amount):
            let seconds = Double(amount.nanoseconds) / 1_000_000_000
            let formatted = String(format: "%.1f", seconds)
            return "operation timed out after \(formatted)s"
        case .noTargets:
            return "no reachable locate targets configured"
        case let .remoteRejected(status, message):
            return "remote rejected request (\(status.rawValue)): \(message)"
        case .missingPingResponse:
            return "missing ping response from server"
        case .invalidAction:
            return "client action does not match requested helper"
        }
    }
}

/// SwiftNIO based UDP client that exercises the cleartext Box protocol.
public enum BoxClient {
    private static let locateAttemptTimeout: TimeAmount = .seconds(5)

    /// Captures a record returned during a synchronisation stream.
    public struct SyncRecord: Sendable {
        public var queuePath: String
        public var contentType: String
        public var data: [UInt8]

        public init(queuePath: String, contentType: String, data: [UInt8]) {
            self.queuePath = queuePath
            self.contentType = contentType
            self.data = data
        }
    }

    /// Boots the UDP client, performs the requested action, and exits when finished.
    /// - Parameter options: Runtime options resolved from the CLI.
    public static func run(with options: BoxRuntimeOptions) async throws {
        _ = try await runInternal(with: options)
    }

    /// Performs a ping action and returns the STATUS message advertised by the server.
    /// - Parameter options: Runtime options configured with `clientAction: .ping`.
    /// - Returns: Server-provided message (includes build metadata).
    public static func ping(with options: BoxRuntimeOptions) async throws -> String {
        guard case .ping = options.clientAction else {
            throw BoxClientError.invalidAction
        }
        let outcome = try await runInternal(with: options)
        guard let message = outcome.pingMessage else {
            throw BoxClientError.missingPingResponse
        }
        return message
    }

    /// Fetches the records returned by a synchronisation stream.
    /// - Parameter options: Runtime options configured with `clientAction: .sync`.
    /// - Returns: Records returned by the remote server.
    public static func sync(with options: BoxRuntimeOptions) async throws -> [SyncRecord] {
        guard case .sync = options.clientAction else {
            throw BoxClientError.invalidAction
        }
        let outcome = try await runInternal(with: options)
        return outcome.syncRecords
    }

    private struct RunOutcome {
        var pingMessage: String?
        var syncRecords: [SyncRecord]

        init(pingMessage: String? = nil, syncRecords: [SyncRecord] = []) {
            self.pingMessage = pingMessage
            self.syncRecords = syncRecords
        }
    }

    private static func runInternal(with options: BoxRuntimeOptions) async throws -> RunOutcome {
        var logger = Logger(label: "box.client")
        logger.logLevel = options.logLevel

        switch options.clientAction {
        case .locate:
            let targets = determineLocateTargets(options: options, logger: logger)
            guard !targets.isEmpty else {
                throw BoxClientError.noTargets
            }

            var lastError: Error?
            for target in targets {
                let remoteAddress: SocketAddress
                do {
                    remoteAddress = try resolveSocketAddress(address: target.address, port: target.port)
                } catch {
                    lastError = BoxClientError.invalidAddress(target.address, target.port)
                    logger.warning("Skipping locate target", metadata: target.failureMetadata(error: error))
                    continue
                }

                do {
                    try await runSingle(
                        with: options,
                        remoteAddress: remoteAddress,
                        timeout: locateAttemptTimeout,
                        logger: logger,
                        attemptMetadata: target.metadata,
                        pingResult: nil,
                        syncRecords: nil
                    )
                    return RunOutcome()
                } catch {
                    lastError = error
                    logger.info("Locate attempt failed", metadata: target.failureMetadata(error: error))
                }
            }

            throw lastError ?? BoxClientError.noTargets

        case .ping:
            let remoteAddress = try resolveSocketAddress(address: options.address, port: options.port)
            let pingBox = NIOLockedValueBox<String?>(nil)
            try await runSingle(
                with: options,
                remoteAddress: remoteAddress,
                timeout: nil,
                logger: logger,
                attemptMetadata: ["target": "single"],
                pingResult: pingBox,
                syncRecords: nil
            )
            let message = pingBox.withLockedValue { $0 }
            return RunOutcome(pingMessage: message)

        case .sync:
            let remoteAddress = try resolveSocketAddress(address: options.address, port: options.port)
            let recordsBox = NIOLockedValueBox<[SyncRecord]>([])
            try await runSingle(
                with: options,
                remoteAddress: remoteAddress,
                timeout: nil,
                logger: logger,
                attemptMetadata: ["target": "single"],
                pingResult: nil,
                syncRecords: recordsBox
            )
            let records = recordsBox.withLockedValue { $0 }
            return RunOutcome(syncRecords: records)

        default:
            let remoteAddress = try resolveSocketAddress(address: options.address, port: options.port)
            try await runSingle(
                with: options,
                remoteAddress: remoteAddress,
                timeout: nil,
                logger: logger,
                attemptMetadata: ["target": "single"],
                pingResult: nil,
                syncRecords: nil
            )
            return RunOutcome()
        }
    }

    private static func runSingle(
        with options: BoxRuntimeOptions,
        remoteAddress: SocketAddress,
        timeout: TimeAmount?,
        logger: Logger,
        attemptMetadata: Logger.Metadata,
        pingResult: NIOLockedValueBox<String?>?,
        syncRecords: NIOLockedValueBox<[SyncRecord]>?
    ) async throws {
        let mergedMetadata = metadata(for: remoteAddress, base: attemptMetadata)
        logger.info("client starting", metadata: mergedMetadata)

        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let completionHolder = NIOLockedValueBox<EventLoopFuture<Void>?>(nil)

        let bootstrap = DatagramBootstrap(group: eventLoopGroup)
            .channelInitializer { channel in
                let handler = BoxClientHandler(
                    remoteAddress: remoteAddress,
                    action: options.clientAction,
                    logger: logger,
                    allocator: channel.allocator,
                    eventLoop: channel.eventLoop,
                    nodeId: options.nodeId,
                    userId: options.userId,
                    timeout: timeout,
                    pingResult: pingResult,
                    syncRecords: syncRecords
                )
                completionHolder.withLockedValue { storage in
                    storage = handler.completionFuture
                }
                return channel.pipeline.addHandler(handler)
            }

        let channel: Channel
        do {
            let bindHost = determineBindHost(remoteAddress: remoteAddress)
            channel = try await bootstrap.bind(host: bindHost, port: 0).get()
        } catch {
            logger.error("failed to bind client UDP socket", metadata: ["error": "\(error)"])
            throw error
        }

        let channelBox = UncheckedSendableBox(channel)

        do {
            guard let operationFuture = completionHolder.withLockedValue({ $0 }) else {
                logger.error("internal error: client completion future missing")
                channelBox.value.close(promise: nil)
                try await eventLoopGroup.shutdownGracefully()
                return
            }

            try await withTaskCancellationHandler {
                try await operationFuture.get()
            } onCancel: {
                logger.info("client cancellation requested", metadata: mergedMetadata)
                channelBox.value.close(promise: nil)
            }

            logger.info("client stopped", metadata: mergedMetadata)
            try await eventLoopGroup.shutdownGracefully()
            return
        } catch {
            var failureMetadata = mergedMetadata
            failureMetadata["error"] = "\(error)"
            logger.error("client failed", metadata: failureMetadata)
            channelBox.value.close(promise: nil)
            try? await eventLoopGroup.shutdownGracefully()
            throw error
        }
    }

    private static func resolveSocketAddress(address: String, port: UInt16) throws -> SocketAddress {
        do {
            return try SocketAddress.makeAddressResolvingHost(address, port: Int(port))
        } catch {
            throw BoxClientError.invalidAddress(address, port)
        }
    }

    static func determineBindHost(remoteAddress: SocketAddress) -> String {
        if let ip = remoteAddress.ipAddress, ip.contains(":") {
            return "::"
        }
        return "0.0.0.0"
    }

    private static func metadata(for remoteAddress: SocketAddress, base: Logger.Metadata) -> Logger.Metadata {
        var result = base
        if let ip = remoteAddress.ipAddress {
            result["address"] = "\(ip)"
        } else {
            result["address"] = "\(remoteAddress)"
        }
        if let port = remoteAddress.port {
            result["port"] = "\(port)"
        }
        return result
    }

    private struct LocateTarget {
        enum Kind: String {
            case explicit
            case configuration
            case localConfirmed
            case localFallback
            case root
        }

        var address: String
        var port: UInt16
        var kind: Kind

        var metadata: Logger.Metadata {
            [
                "target": "\(kind.rawValue)",
                "address": "\(address)",
                "port": "\(port)"
            ]
        }

        func failureMetadata(error: Error) -> Logger.Metadata {
            var data = metadata
            data["error"] = "\(error)"
            return data
        }
    }

    private static func determineLocateTargets(options: BoxRuntimeOptions, logger: Logger) -> [LocateTarget] {
        switch options.addressOrigin {
        case .cliFlag:
            return [LocateTarget(address: options.address, port: options.port, kind: .explicit)]
        case .configuration:
            return [LocateTarget(address: options.address, port: options.port, kind: .configuration)]
        case .default:
            var targets: [LocateTarget] = []
            var seen = Set<String>()

            let localAddress = BoxRuntimeOptions.defaultClientAddress
            let localKey = "\(localAddress):\(options.port)"
            let localReachable = isLocalServerReachable(logger: logger)

            if localReachable {
                targets.append(LocateTarget(address: localAddress, port: options.port, kind: .localConfirmed))
                seen.insert(localKey)
            }

            if !options.rootServers.isEmpty {
                var rng = SystemRandomNumberGenerator()
                for server in options.rootServers.shuffled(using: &rng) {
                    let key = "\(server.address):\(server.port)"
                    if seen.contains(key) {
                        continue
                    }
                    targets.append(LocateTarget(address: server.address, port: server.port, kind: .root))
                    seen.insert(key)
                }
            }

            if targets.isEmpty {
                targets.append(LocateTarget(address: localAddress, port: options.port, kind: .localFallback))
            }

            return targets
        }
    }

    private static func isLocalServerReachable(logger: Logger) -> Bool {
        guard let socketPath = BoxPaths.adminSocketPath() else {
            return false
        }
        let transport = BoxAdminTransportFactory.makeTransport(socketPath: socketPath)
        do {
            _ = try transport.send(command: "ping")
            logger.debug("local admin channel reachable", metadata: ["socket": "\(socketPath)"])
            return true
        } catch {
            logger.debug("local admin channel probe failed", metadata: ["socket": "\(socketPath)", "error": "\(error)"])
            return false
        }
    }
}

/// Channel handler implementing the client state machine (HELLO → STATUS → action).
final class BoxClientHandler: ChannelInboundHandler {
    /// Type of inbound datagrams.
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    /// Type of outbound datagrams.
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    /// State machine describing which response we currently expect.
    private enum Stage {
        /// Waiting for the server HELLO.
        case waitingForHello
        /// Waiting for the STATUS response to our ping.
        case waitingForStatus
        /// Waiting for the PUT acknowledgement (STATUS).
        case waitingForPutAck
        /// Waiting for the GET response (PUT data or STATUS).
        case waitingForGetResponse
        /// Waiting for the locate response (PUT with record or STATUS error).
        case waitingForLocateResponse
        /// Waiting for the remote root to stream synchronisation data.
        case waitingForSyncPayloads
        /// Operation completed.
        case completed
    }

    /// Remote server address.
    private let remoteAddress: SocketAddress
    /// Requested action after the handshake.
    private let action: BoxClientAction
    /// Logger used for diagnostics.
    private let logger: Logger
    /// Channel allocator used to build payloads.
    private let allocator: ByteBufferAllocator
    /// Promise completed once the client sequence finishes.
    private let completionPromise: EventLoopPromise<Void>
    /// Optional timeout applied to the overall locate attempt.
    private let timeout: TimeAmount?
    /// Scheduled timeout task (cancelled when the client completes).
    private var timeoutTask: Scheduled<Void>?
    /// Weak reference to the last active channel context (used for timeouts).
    private weak var activeContext: ChannelHandlerContext?
    /// Optional holder capturing the STATUS payload for ping requests.
    private let pingResult: NIOLockedValueBox<String?>?
    /// Optional holder capturing sync records streamed by the server.
    private let syncRecords: NIOLockedValueBox<[BoxClient.SyncRecord]>?
    /// Convenience accessor exposing the future resolved when the client finishes.
    var completionFuture: EventLoopFuture<Void> {
        completionPromise.futureResult
    }
    /// Node identifier used for outbound frames.
    private let nodeId: UUID
    /// User identifier used for outbound frames.
    private let userId: UUID
    /// Internal stage tracker.
    private var stage: Stage = .waitingForHello

    /// Creates a new client handler.
    /// - Parameters:
    ///   - remoteAddress: Server address we interact with.
    ///   - action: Action executed after the handshake.
    ///   - logger: Logger used for diagnostics.
    ///   - allocator: Channel allocator used to build frames.
    ///   - eventLoop: Event loop owning the handler for promise creation.
    ///   - nodeId: Node identifier propagated over the wire.
    ///   - userId: User identifier propagated over the wire.
    init(
        remoteAddress: SocketAddress,
        action: BoxClientAction,
        logger: Logger,
        allocator: ByteBufferAllocator,
        eventLoop: EventLoop,
        nodeId: UUID,
        userId: UUID,
        timeout: TimeAmount?,
        pingResult: NIOLockedValueBox<String?>?,
        syncRecords: NIOLockedValueBox<[BoxClient.SyncRecord]>?
    ) {
        self.remoteAddress = remoteAddress
        self.action = action
        self.logger = logger
        self.allocator = allocator
        self.completionPromise = eventLoop.makePromise(of: Void.self)
        self.nodeId = nodeId
        self.userId = userId
        self.timeout = timeout
        self.pingResult = pingResult
        self.syncRecords = syncRecords
    }

    /// Sends the initial HELLO when the channel becomes active.
    func channelActive(context: ChannelHandlerContext) {
        activeContext = context
        sendHello(context: context)
        scheduleTimeoutIfNeeded(context: context)
    }

    /// Clears retained state when the channel becomes inactive.
    func channelInactive(context: ChannelHandlerContext) {
        cancelTimeout()
        activeContext = nil
    }

    /// Processes incoming datagrams and advances the state machine.
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        guard envelope.remoteAddress == remoteAddress else {
            logger.debug("Ignoring datagram from unexpected remote", metadata: ["remote": "\(envelope.remoteAddress)"])
            return
        }
        var datagram = envelope.data
        do {
            let frame = try BoxCodec.decodeFrame(from: &datagram)
            try handle(frame: frame, context: context)
        } catch {
            logger.error("Failed to decode client datagram", metadata: ["error": "\(error)"])
            failAndClose(error: error, context: context)
        }
    }

    /// Handles outbound errors by failing the promise and closing the channel.
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.error("client error", metadata: ["error": "\(error)"])
        failAndClose(error: error, context: context)
    }

    /// Sends a HELLO frame to the remote server.
    private func sendHello(context: ChannelHandlerContext) {
        do {
            let payload = try BoxCodec.encodeHelloPayload(status: .ok, versions: [1], allocator: allocator)
            send(
                frame: BoxCodec.Frame(command: .hello, requestId: nextRequestId(), nodeId: nodeId, userId: userId, payload: payload),
                context: context
            )
            stage = .waitingForHello
        } catch {
            logger.error("Failed to encode HELLO payload", metadata: ["error": "\(error)"])
            failAndClose(error: error, context: context)
        }
    }

    /// Handles a decoded frame according to the current stage.
    private func handle(frame: BoxCodec.Frame, context: ChannelHandlerContext) throws {
        switch stage {
        case .waitingForHello:
            try handleHelloResponse(frame: frame, context: context)
        case .waitingForStatus:
            try handleStatusResponse(frame: frame, context: context)
        case .waitingForPutAck:
            try handlePutAck(frame: frame, context: context)
        case .waitingForGetResponse:
            try handleGetResponse(frame: frame, context: context)
        case .waitingForLocateResponse:
            try handleLocateResponse(frame: frame, context: context)
        case .waitingForSyncPayloads:
            try handleSyncStream(frame: frame, context: context)
        case .completed:
            break
        }
    }

    /// Processes the server HELLO, ensuring version compatibility, and sends STATUS.
    private func handleHelloResponse(frame: BoxCodec.Frame, context: ChannelHandlerContext) throws {
        guard frame.command == .hello else {
            logger.warning("Expected HELLO response, received \(frame.command)")
            return
        }
        var payload = frame.payload
        let helloPayload = try BoxCodec.decodeHelloPayload(from: &payload)
        guard helloPayload.supportedVersions.contains(1) else {
            logger.error("Server does not support protocol v1")
            failAndClose(error: BoxCodecError.unsupportedCommand, context: context)
            return
        }

        let statusPayload = BoxCodec.encodeStatusPayload(status: .ok, message: "ping", allocator: allocator)
        send(
            frame: BoxCodec.Frame(command: .status, requestId: nextRequestId(), nodeId: nodeId, userId: userId, payload: statusPayload),
            context: context
        )
        stage = .waitingForStatus
    }

    /// Processes the STATUS response to our ping and dispatches the requested action.
    private func handleStatusResponse(frame: BoxCodec.Frame, context: ChannelHandlerContext) throws {
        guard frame.command == .status else {
            logger.warning("Expected STATUS response, received \(frame.command)")
            return
        }
        var payload = frame.payload
        let statusPayload = try BoxCodec.decodeStatusPayload(from: &payload)
        logger.info("STATUS response", metadata: ["status": "\(statusPayload.status)", "message": "\(statusPayload.message)"])

        switch action {
        case .handshake:
            succeedAndClose(context: context)
        case .ping:
            pingResult?.withLockedValue { $0 = statusPayload.message }
            succeedAndClose(context: context)
        case let .put(queuePath, contentType, data):
            let putPayload = BoxCodec.PutPayload(queuePath: queuePath, contentType: contentType, data: data)
            let buffer = BoxCodec.encodePutPayload(putPayload, allocator: allocator)
            send(
                frame: BoxCodec.Frame(command: .put, requestId: nextRequestId(), nodeId: nodeId, userId: userId, payload: buffer),
                context: context
            )
            stage = .waitingForPutAck
        case let .get(queuePath):
            let getPayload = BoxCodec.GetPayload(queuePath: queuePath)
            let buffer = BoxCodec.encodeGetPayload(getPayload, allocator: allocator)
            send(
                frame: BoxCodec.Frame(command: .get, requestId: nextRequestId(), nodeId: nodeId, userId: userId, payload: buffer),
                context: context
            )
            stage = .waitingForGetResponse
        case let .sync(queuePath):
            let searchPayload = BoxCodec.SearchPayload(queuePath: queuePath)
            let buffer = BoxCodec.encodeSearchPayload(searchPayload, allocator: allocator)
            send(
                frame: BoxCodec.Frame(command: .search, requestId: nextRequestId(), nodeId: nodeId, userId: userId, payload: buffer),
                context: context
            )
            stage = .waitingForSyncPayloads
        case let .locate(node):
            let locatePayload = BoxCodec.LocatePayload(nodeUUID: node)
            let buffer = BoxCodec.encodeLocatePayload(locatePayload, allocator: allocator)
            send(
                frame: BoxCodec.Frame(command: .locate, requestId: nextRequestId(), nodeId: nodeId, userId: userId, payload: buffer),
                context: context
            )
            stage = .waitingForLocateResponse
        }
    }

    /// Processes the STATUS acknowledgement after a PUT command.
    private func handlePutAck(frame: BoxCodec.Frame, context: ChannelHandlerContext) throws {
        guard frame.command == .status else {
            logger.warning("Expected STATUS acknowledgement, received \(frame.command)")
            return
        }
        var payload = frame.payload
        let statusPayload = try BoxCodec.decodeStatusPayload(from: &payload)
        logger.info("PUT acknowledgement", metadata: ["status": "\(statusPayload.status)", "message": "\(statusPayload.message)"])
        if statusPayload.status == .ok {
            succeedAndClose(context: context)
        } else {
            failAndClose(error: BoxClientError.remoteRejected(status: statusPayload.status, message: statusPayload.message), context: context)
        }
    }

    /// Processes the response to a GET command (either PUT payload or STATUS error).
    private func handleGetResponse(frame: BoxCodec.Frame, context: ChannelHandlerContext) throws {
        switch frame.command {
        case .put:
            var payload = frame.payload
            let putPayload = try BoxCodec.decodePutPayload(from: &payload)
            logger.info(
                "GET response",
                metadata: [
                    "queue": "\(putPayload.queuePath)",
                    "type": "\(putPayload.contentType)",
                    "bytes": "\(putPayload.data.count)"
                ]
            )
        case .status:
            var payload = frame.payload
            let statusPayload = try BoxCodec.decodeStatusPayload(from: &payload)
            logger.info(
                "GET status",
                metadata: [
                    "status": "\(statusPayload.status)",
                    "message": "\(statusPayload.message)"
                ]
            )
            if statusPayload.status != .ok {
                failAndClose(error: BoxClientError.remoteRejected(status: statusPayload.status, message: statusPayload.message), context: context)
                return
            }
        default:
            logger.warning("Unexpected command while awaiting GET response", metadata: ["command": "\(frame.command)"])
            return
        }
        succeedAndClose(context: context)
    }

    /// Processes the response to a Locate command (either PUT payload or STATUS error).
    private func handleLocateResponse(frame: BoxCodec.Frame, context: ChannelHandlerContext) throws {
        switch frame.command {
        case .put:
            var payload = frame.payload
            let putPayload = try BoxCodec.decodePutPayload(from: &payload)
            let data = Data(putPayload.data)
            if let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []),
               let dictionary = jsonObject as? [String: Any] {
                logger.info(
                    "LOCATE response",
                    metadata: [
                        "node": "\(dictionary["node_uuid"] ?? putPayload.queuePath)",
                        "contentType": "\(putPayload.contentType)"
                    ]
                )
            } else {
                logger.info(
                    "LOCATE response (raw)",
                    metadata: [
                        "bytes": "\(putPayload.data.count)",
                        "contentType": "\(putPayload.contentType)"
                    ]
                )
            }
            succeedAndClose(context: context)
        case .status:
            var payload = frame.payload
            let statusPayload = try BoxCodec.decodeStatusPayload(from: &payload)
            logger.error(
                "LOCATE request failed",
                metadata: [
                    "status": "\(statusPayload.status)",
                    "message": "\(statusPayload.message)"
                ]
            )
            let error = NSError(
                domain: "BoxClientLocate",
                code: Int(statusPayload.status.rawValue),
                userInfo: [NSLocalizedDescriptionKey: statusPayload.message]
            )
            failAndClose(error: error, context: context)
        default:
            logger.warning("Unexpected command while awaiting LOCATE response", metadata: ["command": "\(frame.command)"])
        }
    }

    /// Processes the frames composing a sync stream (PUT objects followed by STATUS).
    private func handleSyncStream(frame: BoxCodec.Frame, context: ChannelHandlerContext) throws {
        switch frame.command {
        case .put:
            var payload = frame.payload
            let putPayload = try BoxCodec.decodePutPayload(from: &payload)
            syncRecords?.withLockedValue { storage in
                storage.append(
                    BoxClient.SyncRecord(
                        queuePath: putPayload.queuePath,
                        contentType: putPayload.contentType,
                        data: putPayload.data
                    )
                )
            }
            logger.debug(
                "SYNC record received",
                metadata: [
                    "queue": "\(putPayload.queuePath)",
                    "contentType": "\(putPayload.contentType)",
                    "bytes": "\(putPayload.data.count)"
                ]
            )
        case .status:
            var payload = frame.payload
            let statusPayload = try BoxCodec.decodeStatusPayload(from: &payload)
            guard statusPayload.status == .ok else {
                logger.error(
                    "SYNC rejected",
                    metadata: [
                        "status": "\(statusPayload.status)",
                        "message": "\(statusPayload.message)"
                    ]
                )
                failAndClose(
                    error: BoxClientError.remoteRejected(status: statusPayload.status, message: statusPayload.message),
                    context: context
                )
                return
            }
            logger.info("SYNC completed", metadata: ["message": "\(statusPayload.message)"])
            succeedAndClose(context: context)
        default:
            logger.warning("Unexpected command during SYNC stream", metadata: ["command": "\(frame.command)"])
        }
    }

    /// Serialises and sends a frame to the remote endpoint.
    private func send(frame: BoxCodec.Frame, context: ChannelHandlerContext) {
        let datagram = BoxCodec.encodeFrame(frame, allocator: allocator)
        let envelope = AddressedEnvelope(remoteAddress: remoteAddress, data: datagram)
        context.writeAndFlush(wrapOutboundOut(envelope), promise: nil)
    }

    /// Allocates the next request identifier (monotonic increment).
    private func nextRequestId() -> UUID {
        UUID()
    }

    /// Completes the promise successfully and closes the channel.
    private func succeedAndClose(context: ChannelHandlerContext) {
        guard stage != .completed else {
            return
        }
        stage = .completed
        cancelTimeout()
        completionPromise.succeed(())
        context.close(promise: nil)
    }

    /// Fails the promise with the provided error and closes the channel.
    private func failAndClose(error: Error, context: ChannelHandlerContext) {
        guard stage != .completed else {
            return
        }
        stage = .completed
        cancelTimeout()
        completionPromise.fail(error)
        context.close(promise: nil)
    }

    /// Cancels the timeout task if it is still pending.
    private func cancelTimeout() {
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    /// Schedules the timeout guard when a timeout value was supplied.
    private func scheduleTimeoutIfNeeded(context: ChannelHandlerContext) {
        guard timeoutTask == nil, let timeout else {
            return
        }
        timeoutTask = context.eventLoop.scheduleTask(in: timeout) { [weak self] in
            guard let self else {
                return
            }
            self.logger.error("client timeout", metadata: ["timeout": "\(timeout)"])
            guard let context = self.activeContext else {
                return
            }
            self.failAndClose(error: BoxClientError.timeout(timeout), context: context)
        }
    }
}

extension BoxClientHandler: @unchecked Sendable {}
