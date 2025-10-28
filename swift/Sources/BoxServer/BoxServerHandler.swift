import BoxCore
import Foundation
import Logging
import NIOCore

final class BoxServerHandler: ChannelInboundHandler {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    private let logger: Logger
    private let allocator: ByteBufferAllocator
    private let store: BoxServerStore
    private let identityProvider: @Sendable () -> (UUID, UUID)
    private let authorizer: @Sendable (UUID, UUID) async -> Bool
    private let locationResolver: @Sendable (UUID) async -> LocationServiceNodeRecord?
    private let jsonEncoder: JSONEncoder
    private let isPermanentQueue: @Sendable (String) -> Bool

    init(
        logger: Logger,
        allocator: ByteBufferAllocator,
        store: BoxServerStore,
        identityProvider: @escaping @Sendable () -> (UUID, UUID),
        authorizer: @escaping @Sendable (UUID, UUID) async -> Bool,
        locationResolver: @escaping @Sendable (UUID) async -> LocationServiceNodeRecord?,
        isPermanentQueue: @escaping @Sendable (String) -> Bool
    ) {
        self.logger = logger
        self.allocator = allocator
        self.store = store
        self.identityProvider = identityProvider
        self.authorizer = authorizer
        self.locationResolver = locationResolver
        self.isPermanentQueue = isPermanentQueue
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
                    let contextValue = contextBox.value
                    self.send(command: .status, requestId: requestId, payload: statusPayload, to: remoteAddress, context: contextValue)
                }
            } catch {
                logger.error(
                    "failed to store object",
                    metadata: ["queue": .string(queuePath), "error": .string("\(error)")]
                )
                eventLoop.execute {
                    let statusPayload = BoxCodec.encodeStatusPayload(status: .internalError, message: "storage-error", allocator: allocator)
                    let contextValue = contextBox.value
                    self.send(command: .status, requestId: requestId, payload: statusPayload, to: remoteAddress, context: contextValue)
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
        let permanent = self.isPermanentQueue(queuePath)

        Task {
            do {
                let object: BoxStoredObject?
                if permanent {
                    object = try await store.peekOldest(from: queuePath)
                } else {
                    object = try await store.popOldest(from: queuePath)
                }
                if let object {
                    eventLoop.execute {
                        let responsePayload = BoxCodec.encodePutPayload(
                            BoxCodec.PutPayload(queuePath: queuePath, contentType: object.contentType, data: object.data),
                            allocator: allocator
                        )
                        let contextValue = contextBox.value
                        self.send(command: .put, requestId: requestId, payload: responsePayload, to: remoteAddress, context: contextValue)
                    }
                } else {
                    eventLoop.execute {
                        let statusPayload = BoxCodec.encodeStatusPayload(status: .badRequest, message: "not-found", allocator: allocator)
                        let contextValue = contextBox.value
                        self.send(command: .status, requestId: requestId, payload: statusPayload, to: remoteAddress, context: contextValue)
                    }
                }
            } catch {
                logger.error(
                    "failed to fetch object",
                    metadata: ["queue": .string(queuePath), "error": .string("\(error)")]
                )
                eventLoop.execute {
                    let statusPayload = BoxCodec.encodeStatusPayload(status: .internalError, message: "storage-error", allocator: allocator)
                    let contextValue = contextBox.value
                    self.send(command: .status, requestId: requestId, payload: statusPayload, to: remoteAddress, context: contextValue)
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
                    let contextValue = contextBox.value
                    self.send(command: .status, requestId: requestId, payload: statusPayload, to: remoteAddress, context: contextValue)
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
                        let contextValue = contextBox.value
                        self.send(command: .put, requestId: requestId, payload: responsePayload, to: remoteAddress, context: contextValue)
                    } catch {
                        logger.error("failed to encode location record", metadata: ["error": .string("\(error)")])
                        let statusPayload = BoxCodec.encodeStatusPayload(status: .internalError, message: "encoding-error", allocator: allocator)
                        let contextValue = contextBox.value
                        self.send(command: .status, requestId: requestId, payload: statusPayload, to: remoteAddress, context: contextValue)
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
                    let contextValue = contextBox.value
                    self.send(command: .status, requestId: requestId, payload: statusPayload, to: remoteAddress, context: contextValue)
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
