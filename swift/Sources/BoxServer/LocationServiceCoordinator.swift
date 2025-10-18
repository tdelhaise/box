import BoxCore
import Foundation
import Logging

/// Coordinates publication of Location Service records into the local queue store.
actor LocationServiceCoordinator {
    private enum Constants {
        static let queueName = "/uuid"
        static let contentType = "application/json; charset=utf-8"
        static let schema = "box.location-service.v1"
    }

    private let store: BoxServerStore
    private let logger: Logger
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(store: BoxServerStore, logger: Logger) {
        self.store = store
        self.logger = logger
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    /// Ensures the Location Service queue exists before publishing records.
    func bootstrap() async throws {
        _ = try await store.ensureQueue(Constants.queueName)
    }

    /// Publishes the supplied record into the Location Service queue, replacing any previous entry for the same node.
    /// - Parameter record: Snapshot describing the current node state.
    func publish(record: LocationServiceNodeRecord) async {
        do {
            let data = try encoder.encode(record)
            let payloadBytes = [UInt8](data)
            let storedObject = BoxStoredObject(
                id: record.nodeUUID,
                contentType: Constants.contentType,
                data: payloadBytes,
                createdAt: Date(),
                nodeId: record.nodeUUID,
                userId: record.userUUID,
                userMetadata: ["schema": Constants.schema]
            )
            do {
                try await store.remove(queue: Constants.queueName, id: record.nodeUUID)
            } catch {
                if case BoxStoreError.objectNotFound = error {
                    // No-op, we are publishing for the first time.
                } else if case BoxStoreError.queueNotFound = error {
                    logger.warning("location service queue missing during publish", metadata: ["error": .string("\(error)")])
                    try await store.ensureQueue(Constants.queueName)
                } else {
                    logger.warning("failed to clear existing location record", metadata: ["error": .string("\(error)")])
                }
            }

            _ = try await store.put(storedObject, into: Constants.queueName)
            logger.debug(
                "location service record persisted",
                metadata: [
                    "node": .string(record.nodeUUID.uuidString),
                    "user": .string(record.userUUID.uuidString),
                    "addresses": .array(record.addresses.map { .string("\($0.ip):\($0.port)") })
                ]
            )
        } catch {
            logger.error("failed to publish location service record", metadata: ["error": .string("\(error)")])
        }
    }

    /// Returns the list of Location Service records currently persisted.
    /// - Returns: Array of node records discovered in the queue.
    func snapshot() async -> [LocationServiceNodeRecord] {
        do {
            let references = try await store.list(queue: Constants.queueName)
            var records: [LocationServiceNodeRecord] = []
            records.reserveCapacity(references.count)
            for reference in references {
                do {
                    let object = try await store.read(reference: reference)
                    if let record = decode(object: object) {
                        records.append(record)
                    }
                } catch {
                    logger.warning("failed to decode location record", metadata: ["file": .string(reference.url.lastPathComponent), "error": .string("\(error)")])
                }
            }
            return records.sorted { $0.nodeUUID.uuidString < $1.nodeUUID.uuidString }
        } catch {
            logger.error("failed to enumerate location service records", metadata: ["error": .string("\(error)")])
            return []
        }
    }

    /// Resolves all nodes belonging to the supplied user.
    /// - Parameter userUUID: Identifier of the user being resolved.
    /// - Returns: Array of node records owned by the user (may be empty).
    func resolve(userUUID: UUID) async -> [LocationServiceNodeRecord] {
        await snapshot().filter { $0.userUUID == userUUID }
    }

    /// Resolves a node by identifier.
    /// - Parameter nodeUUID: Identifier of the node.
    /// - Returns: The record when present.
    func resolve(nodeUUID: UUID) async -> LocationServiceNodeRecord? {
        await snapshot().first { $0.nodeUUID == nodeUUID }
    }

    /// Returns whether the provided node/user identity is known to the Location Service.
    /// - Parameters:
    ///   - nodeUUID: Identifier of the requesting node.
    ///   - userUUID: Identifier of the requesting user.
    /// - Returns: `true` when the combination is known, `false` otherwise.
    func authorize(nodeUUID: UUID, userUUID: UUID) async -> Bool {
        guard let record = await resolve(nodeUUID: nodeUUID) else {
            return false
        }
        return record.userUUID == userUUID
    }

    private func decode(object: BoxStoredObject) -> LocationServiceNodeRecord? {
        guard object.contentType.lowercased().hasPrefix("application/json") else {
            return nil
        }
        if let schema = object.userMetadata?["schema"], schema != Constants.schema {
            return nil
        }
        do {
            return try decoder.decode(LocationServiceNodeRecord.self, from: Data(object.data))
        } catch {
            logger.warning(
                "unable to decode location record payload",
                metadata: ["node": .string(object.nodeId.uuidString), "error": .string("\(error)")]
            )
            return nil
        }
    }
}
