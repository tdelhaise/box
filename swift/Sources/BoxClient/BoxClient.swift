import BoxCore
import Foundation
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

/// SwiftNIO based UDP client that exercises the cleartext Box protocol.
public enum BoxClient {
    /// Boots the UDP client, performs the requested action, and exits when finished.
    /// - Parameter options: Runtime options resolved from the CLI.
    public static func run(with options: BoxRuntimeOptions) async throws {
        let logger = Logger(label: "box.client")
        logger.info("client starting", metadata: ["address": "\(options.address)", "port": "\(options.port)"])

        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let completionHolder = NIOLockedValueBox<EventLoopFuture<Void>?>(nil)

        let remoteAddress = try SocketAddress(ipAddress: options.address, port: Int(options.port))

        let bootstrap = DatagramBootstrap(group: eventLoopGroup)
            .channelInitializer { channel in
                let handler = BoxClientHandler(
                    remoteAddress: remoteAddress,
                    action: options.clientAction,
                    logger: logger,
                    allocator: channel.allocator,
                    eventLoop: channel.eventLoop,
                    nodeId: options.nodeId,
                    userId: options.userId
                )
                completionHolder.withLockedValue { storage in
                    storage = handler.completionFuture
                }
                return channel.pipeline.addHandler(handler)
            }

        let channel: Channel
        do {
            channel = try await bootstrap.bind(host: "0.0.0.0", port: 0).get()
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
                logger.info("client cancellation requested")
                channelBox.value.close(promise: nil)
            }

            logger.info("client stopped")
            try await eventLoopGroup.shutdownGracefully()
        } catch {
            logger.error("client failed", metadata: ["error": "\(error)"])
            channelBox.value.close(promise: nil)
            try? await eventLoopGroup.shutdownGracefully()
            throw error
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
        userId: UUID
    ) {
        self.remoteAddress = remoteAddress
        self.action = action
        self.logger = logger
        self.allocator = allocator
        self.completionPromise = eventLoop.makePromise(of: Void.self)
        self.nodeId = nodeId
        self.userId = userId
    }

    /// Sends the initial HELLO when the channel becomes active.
    func channelActive(context: ChannelHandlerContext) {
        sendHello(context: context)
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
        succeedAndClose(context: context)
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
        completionPromise.succeed(())
        context.close(promise: nil)
    }

    /// Fails the promise with the provided error and closes the channel.
    private func failAndClose(error: Error, context: ChannelHandlerContext) {
        guard stage != .completed else {
            return
        }
        stage = .completed
        completionPromise.fail(error)
        context.close(promise: nil)
    }
}

extension BoxClientHandler: @unchecked Sendable {}
