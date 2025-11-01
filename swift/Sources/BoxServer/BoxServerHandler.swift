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
        case .locate:
            try handleLocate(payload: &payload, frame: frame, remote: remote, context: context)
        case .search:
            try handleSearch(payload: &payload, frame: frame, remote: remote, context: context)
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
        let buildMessage = "pong \(BoxVersionInfo.description)"
        let pongPayload = BoxCodec.encodeStatusPayload(status: .ok, message: buildMessage, allocator: allocator)
        send(command: .status, requestId: frame.requestId, payload: pongPayload, to: remote, context: context)
    }

    private func handlePut(payload: inout ByteBuffer, frame: BoxCodec.Frame, remote: SocketAddress, context: ChannelHandlerContext) throws {
        let putPayload = try BoxCodec.decodePutPayload(from: &payload)
        let queuePath = putPayload.queuePath
        let requestId = frame.requestId
        let normalizedQueue: String
        do {
            normalizedQueue = try BoxServerStore.normalizeQueueName(queuePath)
        } catch {
            let allocator = self.allocator
            let eventLoop = context.eventLoop
            let contextBox = UncheckedSendableBox(context)
            let remoteAddress = remote
            eventLoop.execute {
                self.logger.debug(
                    "rejecting put due to invalid queue name",
                    metadata: ["queue": .string(queuePath), "error": .string("\(error)")]
                )
                let statusPayload = BoxCodec.encodeStatusPayload(status: .badRequest, message: "invalid-queue", allocator: allocator)
                let contextValue = contextBox.value
                self.send(command: .status, requestId: requestId, payload: statusPayload, to: remoteAddress, context: contextValue)
            }
            return
        }

        let nodeId = frame.nodeId
        let userId = frame.userId
        let contentType = putPayload.contentType
        let payloadBytes = putPayload.data
        let store = self.store
        let logger = self.logger
        let allocator = self.allocator
        let eventLoop = context.eventLoop
        let contextBox = UncheckedSendableBox(context)
        let remoteAddress = remote
        let authorizer = self.authorizer

        Task {
            let permitted = await authorizer(nodeId, userId)
            let allowRegistration = (!permitted) && self.shouldAcceptSelfRegistration(
                queue: normalizedQueue,
                contentType: contentType,
                payloadBytes: payloadBytes,
                nodeId: nodeId,
                userId: userId
            )

            guard permitted || allowRegistration else {
                eventLoop.execute {
                    logger.debug(
                        "rejecting put due to unauthorized identity",
                        metadata: [
                            "queue": .string(normalizedQueue),
                            "requestNode": .string(nodeId.uuidString),
                            "requestUser": .string(userId.uuidString)
                        ]
                    )
                    let statusPayload = BoxCodec.encodeStatusPayload(status: .unauthorized, message: "unknown-client", allocator: allocator)
                    let contextValue = contextBox.value
                    self.send(command: .status, requestId: requestId, payload: statusPayload, to: remoteAddress, context: contextValue)
                }
                return
            }

            do {
                let storedObject: BoxStoredObject
                if normalizedQueue.caseInsensitiveCompare("whoswho") == .orderedSame {
                    let data = Data(payloadBytes)
                    let decoder = JSONDecoder()
                    if let nodeRecord = try? decoder.decode(LocationServiceNodeRecord.self, from: data) {
                        storedObject = BoxStoredObject(
                            id: nodeRecord.nodeUUID,
                            contentType: contentType,
                            data: payloadBytes,
                            createdAt: Date(),
                            nodeId: nodeRecord.nodeUUID,
                            userId: nodeRecord.userUUID,
                            userMetadata: ["schema": LocationServiceCoordinator.nodeSchemaIdentifier]
                        )
                    } else if let userRecord = try? decoder.decode(LocationServiceUserRecord.self, from: data) {
                        storedObject = BoxStoredObject(
                            id: userRecord.userUUID,
                            contentType: contentType,
                            data: payloadBytes,
                            createdAt: Date(),
                            nodeId: userRecord.nodeUUIDs.first ?? nodeId,
                            userId: userRecord.userUUID,
                            userMetadata: ["schema": LocationServiceCoordinator.userSchemaIdentifier]
                        )
                    } else {
                        storedObject = BoxStoredObject(
                            contentType: contentType,
                            data: payloadBytes,
                            nodeId: nodeId,
                            userId: userId
                        )
                    }
                } else {
                    storedObject = BoxStoredObject(
                        contentType: contentType,
                        data: payloadBytes,
                        nodeId: nodeId,
                        userId: userId
                    )
                }
                try await store.put(storedObject, into: normalizedQueue)
                logger.info(
                    "stored object on queue \(normalizedQueue)",
                    metadata: [
                        "queue": .string(normalizedQueue),
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
                    metadata: ["queue": .string(normalizedQueue), "error": .string("\(error)")]
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
        let authorizer = self.authorizer
        let nodeId = frame.nodeId
        let userId = frame.userId

        let normalizedQueue: String
        do {
            normalizedQueue = try BoxServerStore.normalizeQueueName(queuePath)
        } catch {
            eventLoop.execute {
                logger.debug(
                    "rejecting get due to invalid queue name",
                    metadata: ["queue": .string(queuePath), "error": .string("\(error)")]
                )
                let statusPayload = BoxCodec.encodeStatusPayload(status: .badRequest, message: "invalid-queue", allocator: allocator)
                let contextValue = contextBox.value
                self.send(command: .status, requestId: requestId, payload: statusPayload, to: remoteAddress, context: contextValue)
            }
            return
        }

        Task {
            let permitted = await authorizer(nodeId, userId)
            guard permitted else {
                eventLoop.execute {
                    logger.debug(
                        "rejecting get due to unauthorized identity",
                        metadata: [
                            "queue": .string(normalizedQueue),
                            "requestNode": .string(nodeId.uuidString),
                            "requestUser": .string(userId.uuidString)
                        ]
                    )
                    let statusPayload = BoxCodec.encodeStatusPayload(status: .unauthorized, message: "unknown-client", allocator: allocator)
                    let contextValue = contextBox.value
                    self.send(command: .status, requestId: requestId, payload: statusPayload, to: remoteAddress, context: contextValue)
                }
                return
            }

            do {
                let object: BoxStoredObject?
                if permanent {
                    object = try await store.peekOldest(from: normalizedQueue)
                } else {
                    object = try await store.popOldest(from: normalizedQueue)
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

    private func handleSearch(payload: inout ByteBuffer, frame: BoxCodec.Frame, remote: SocketAddress, context: ChannelHandlerContext) throws {
        let searchPayload = try BoxCodec.decodeSearchPayload(from: &payload)
        let queuePath = searchPayload.queuePath
        let store = self.store
        let allocator = self.allocator
        let logger = self.logger
        let requestId = frame.requestId
        let eventLoop = context.eventLoop
        let contextBox = UncheckedSendableBox(context)
        let remoteAddress = remote
        let authorizer = self.authorizer
        let nodeId = frame.nodeId
        let userId = frame.userId

        let normalizedQueue: String
        do {
            normalizedQueue = try BoxServerStore.normalizeQueueName(queuePath)
        } catch {
            eventLoop.execute {
                logger.debug(
                    "rejecting search due to invalid queue name",
                    metadata: ["queue": .string(queuePath), "error": .string("\(error)")]
                )
                let statusPayload = BoxCodec.encodeStatusPayload(status: .badRequest, message: "invalid-queue", allocator: allocator)
                let contextValue = contextBox.value
                self.send(command: .status, requestId: requestId, payload: statusPayload, to: remoteAddress, context: contextValue)
            }
            return
        }

        Task {
            let permitted = await authorizer(nodeId, userId)
            guard permitted else {
                eventLoop.execute {
                    logger.debug(
                        "rejecting search due to unauthorized identity",
                        metadata: [
                            "queue": .string(normalizedQueue),
                            "requestNode": .string(nodeId.uuidString),
                            "requestUser": .string(userId.uuidString)
                        ]
                    )
                    let statusPayload = BoxCodec.encodeStatusPayload(status: .unauthorized, message: "unknown-client", allocator: allocator)
                    let contextValue = contextBox.value
                    self.send(command: .status, requestId: requestId, payload: statusPayload, to: remoteAddress, context: contextValue)
                }
                return
            }

            do {
                let references: [BoxMessageRef]
                do {
                    references = try await store.list(queue: normalizedQueue)
                } catch let error as BoxStoreError {
                    if case .queueNotFound = error {
                        eventLoop.execute {
                            logger.debug(
                                "search queue missing, returning empty response",
                                metadata: ["queue": .string(normalizedQueue)]
                            )
                            let statusPayload = BoxCodec.encodeStatusPayload(status: .ok, message: "sync-empty", allocator: allocator)
                            let contextValue = contextBox.value
                            self.send(command: .status, requestId: requestId, payload: statusPayload, to: remoteAddress, context: contextValue)
                        }
                        return
                    }
                    throw error
                }

                var objects: [BoxStoredObject] = []
                objects.reserveCapacity(references.count)

                for reference in references {
                    do {
                        let object = try await store.read(reference: reference)
                        objects.append(object)
                    } catch {
                        logger.warning(
                            "failed to read object during search",
                            metadata: [
                                "queue": .string(normalizedQueue),
                                "file": .string(reference.url.lastPathComponent),
                                "error": .string("\(error)")
                            ]
                        )
                    }
                }

                let objectsToSend = objects
                eventLoop.execute {
                    let contextValue = contextBox.value
                    for object in objectsToSend {
                        let putPayload = BoxCodec.PutPayload(queuePath: queuePath, contentType: object.contentType, data: object.data)
                        let buffer = BoxCodec.encodePutPayload(putPayload, allocator: allocator)
                        self.send(command: .put, requestId: requestId, payload: buffer, to: remoteAddress, context: contextValue)
                    }
                    let statusPayload = BoxCodec.encodeStatusPayload(status: .ok, message: "sync-complete", allocator: allocator)
                    self.send(command: .status, requestId: requestId, payload: statusPayload, to: remoteAddress, context: contextValue)
                }
            } catch {
                logger.error(
                    "search processing failed",
                    metadata: ["queue": .string(normalizedQueue), "error": .string("\(error)")]
                )
                eventLoop.execute {
                    let statusPayload = BoxCodec.encodeStatusPayload(status: .internalError, message: "sync-error", allocator: allocator)
                    let contextValue = contextBox.value
                    self.send(command: .status, requestId: requestId, payload: statusPayload, to: remoteAddress, context: contextValue)
                }
            }
        }
    }

    private func shouldAcceptSelfRegistration(queue: String, contentType: String, payloadBytes: [UInt8], nodeId: UUID, userId: UUID) -> Bool {
        guard queue.caseInsensitiveCompare("whoswho") == .orderedSame else {
            return false
        }
        guard contentType.lowercased().hasPrefix("application/json") else {
            return false
        }
        let decoder = JSONDecoder()
        let data = Data(payloadBytes)
        if let nodeRecord = try? decoder.decode(LocationServiceNodeRecord.self, from: data) {
            return nodeRecord.nodeUUID == nodeId && nodeRecord.userUUID == userId
        }
        if let userRecord = try? decoder.decode(LocationServiceUserRecord.self, from: data) {
            return userRecord.userUUID == userId && userRecord.nodeUUIDs.contains(nodeId)
        }
        return false
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
