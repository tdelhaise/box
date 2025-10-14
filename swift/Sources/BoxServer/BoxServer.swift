import BoxCore
import Logging
import NIOCore
import NIOPosix

/// SwiftNIO based UDP server implementing the Box protocol in cleartext mode.
public enum BoxServer {
    /// Boots the UDP server and keeps running until the channel is closed or the task is cancelled.
    /// - Parameter options: Runtime options resolved from the CLI or configuration file.
    public static func run(with options: BoxRuntimeOptions) async throws {
        let logger = Logger(label: "box.server")
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

        let bootstrap = DatagramBootstrap(group: eventLoopGroup)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandler(BoxServerHandler(logger: logger, allocator: channel.allocator))
            }

        do {
            let channel = try await bootstrap.bind(host: options.address, port: Int(options.port)).get()
            let channelBox = UncheckedSendableBox(channel)
            logger.info("server listening", metadata: ["address": "\(options.address)", "port": "\(options.port)"])

            try await withTaskCancellationHandler {
                try await channelBox.value.closeFuture.get()
            } onCancel: {
                logger.info("server cancellation requested")
                channelBox.value.close(promise: nil)
            }

            logger.info("server stopped")
            try await eventLoopGroup.shutdownGracefully()
        } catch {
            logger.error("server failed", metadata: ["error": "\(error)"])
            try? await eventLoopGroup.shutdownGracefully()
            throw error
        }
    }
}

/// In-memory stored object used for the cleartext PUT/GET demo.
private struct BoxStoredObject {
    /// Content type associated with the stored payload.
    var contentType: String
    /// Stored payload bytes.
    var data: [UInt8]
}

/// Channel handler that decodes incoming datagrams and produces responses.
final class BoxServerHandler: ChannelInboundHandler {
    /// Type of inbound messages handled by the datagram channel.
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    /// Type of outbound messages produced by the handler.
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    /// Logger shared with the server runtime.
    private let logger: Logger
    /// Allocator sourced from the channel for constructing payloads.
    private let allocator: ByteBufferAllocator
    /// Simple in-memory store keyed by queue path.
    private var storage: [String: BoxStoredObject]

    /// Creates a new handler instance.
    /// - Parameters:
    ///   - logger: Logger used for diagnostics.
    ///   - allocator: Channel allocator used when producing responses.
    init(logger: Logger, allocator: ByteBufferAllocator) {
        self.logger = logger
        self.allocator = allocator
        self.storage = [:]
    }

    /// Processes inbound datagrams, decodes frames, and routes commands.
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

    /// Handles a decoded frame and emits an eventual response.
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
            send(
                frame: BoxCodec.Frame(command: .status, requestId: frame.requestId + 1, payload: statusPayload),
                to: remote,
                context: context
            )
        }
    }

    /// Responds to a HELLO handshake.
    private func respondToHello(payload: inout ByteBuffer, frame: BoxCodec.Frame, remote: SocketAddress, context: ChannelHandlerContext) throws {
        let hello = try BoxCodec.decodeHelloPayload(from: &payload)
        guard hello.supportedVersions.contains(1) else {
            logger.info("HELLO without compatible version", metadata: ["remote": "\(remote)"])
            let statusPayload = BoxCodec.encodeStatusPayload(
                status: .badRequest,
                message: "unsupported-version",
                allocator: allocator
            )
            send(
                frame: BoxCodec.Frame(command: .status, requestId: frame.requestId + 1, payload: statusPayload),
                to: remote,
                context: context
            )
            return
        }
        let responsePayload = try BoxCodec.encodeHelloPayload(
            status: .ok,
            versions: [1],
            allocator: allocator
        )
        send(
            frame: BoxCodec.Frame(command: .hello, requestId: frame.requestId + 1, payload: responsePayload),
            to: remote,
            context: context
        )
    }

    /// Responds to a STATUS ping with a STATUS pong.
    private func respondToStatus(frame: BoxCodec.Frame, remote: SocketAddress, context: ChannelHandlerContext) throws {
        var payload = frame.payload
        let status = try BoxCodec.decodeStatusPayload(from: &payload)
        logger.debug("STATUS received", metadata: ["status": "\(status.status)", "message": "\(status.message)"])
        let pongPayload = BoxCodec.encodeStatusPayload(
            status: .ok,
            message: "pong",
            allocator: allocator
        )
        send(
            frame: BoxCodec.Frame(command: .status, requestId: frame.requestId + 1, payload: pongPayload),
            to: remote,
            context: context
        )
    }

    /// Handles a PUT command by storing the payload.
    private func handlePut(payload: inout ByteBuffer, frame: BoxCodec.Frame, remote: SocketAddress, context: ChannelHandlerContext) throws {
        let putPayload = try BoxCodec.decodePutPayload(from: &payload)
        storage[putPayload.queuePath] = BoxStoredObject(contentType: putPayload.contentType, data: putPayload.data)
        logger.info("stored object", metadata: ["queue": "\(putPayload.queuePath)", "bytes": "\(putPayload.data.count)"])
        let statusPayload = BoxCodec.encodeStatusPayload(
            status: .ok,
            message: "stored",
            allocator: allocator
        )
        send(
            frame: BoxCodec.Frame(command: .status, requestId: frame.requestId + 1, payload: statusPayload),
            to: remote,
            context: context
        )
    }

    /// Handles a GET command by returning the stored object or a status error.
    private func handleGet(payload: inout ByteBuffer, frame: BoxCodec.Frame, remote: SocketAddress, context: ChannelHandlerContext) throws {
        let getPayload = try BoxCodec.decodeGetPayload(from: &payload)
        if let object = storage[getPayload.queuePath] {
            let responsePayload = BoxCodec.encodePutPayload(
                BoxCodec.PutPayload(queuePath: getPayload.queuePath, contentType: object.contentType, data: object.data),
                allocator: allocator
            )
            send(
                frame: BoxCodec.Frame(command: .put, requestId: frame.requestId + 1, payload: responsePayload),
                to: remote,
                context: context
            )
        } else {
            let statusPayload = BoxCodec.encodeStatusPayload(
                status: .badRequest,
                message: "not-found",
                allocator: allocator
            )
            send(
                frame: BoxCodec.Frame(command: .status, requestId: frame.requestId + 1, payload: statusPayload),
                to: remote,
                context: context
            )
        }
    }

    /// Serialises the supplied frame and writes it to the channel.
    private func send(frame: BoxCodec.Frame, to remote: SocketAddress, context: ChannelHandlerContext) {
        let datagram = BoxCodec.encodeFrame(frame, allocator: allocator)
        let envelope = AddressedEnvelope(remoteAddress: remote, data: datagram)
        context.writeAndFlush(wrapOutboundOut(envelope), promise: nil)
    }
}

extension BoxServerHandler: @unchecked Sendable {}
