import BoxCore
import Logging
import NIOCore

final class BoxAdminChannelHandler: ChannelInboundHandler {
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
