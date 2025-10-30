import BoxCore
import Foundation
import Logging

/// Coordinates publication of Location Service records into the local queue store.
actor LocationServiceCoordinator {
    private enum Constants {
        static let queueName = "/whoswho"
        static let contentType = "application/json; charset=utf-8"
        static let nodeSchema = "box.location-service.v1"
        static let userSchema = "box.location-service.user.v1"
    }

    struct Summary: Sendable {
        let generatedAt: Date
        let totalNodes: Int
        let totalUsers: Int
        let activeNodes: Int
        let staleNodes: [UUID]
        let staleUsers: [UUID]
        let staleThresholdSeconds: Int
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
                userMetadata: ["schema": Constants.nodeSchema]
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
            await publishUserIndex(for: record.userUUID)
        } catch {
            logger.error("failed to publish location service record", metadata: ["error": .string("\(error)")])
        }
    }

    private func publishUserIndex(for userUUID: UUID) async {
        do {
            let nodes = await resolve(userUUID: userUUID)
            let nodeIDs = Array(Set(nodes.map { $0.nodeUUID })).sorted { $0.uuidString < $1.uuidString }
            let userRecord = LocationServiceUserRecord.make(userUUID: userUUID, nodeUUIDs: nodeIDs)
            let data = try encoder.encode(userRecord)
            let payloadBytes = [UInt8](data)
            let storedObject = BoxStoredObject(
                id: userUUID,
                contentType: Constants.contentType,
                data: payloadBytes,
                createdAt: Date(),
                nodeId: nodeIDs.first ?? userUUID,
                userId: userUUID,
                userMetadata: ["schema": Constants.userSchema]
            )
            do {
                try await store.remove(queue: Constants.queueName, id: userUUID)
            } catch {
                if case BoxStoreError.objectNotFound = error {
                    // First publish for this user.
                } else if case BoxStoreError.queueNotFound = error {
                    logger.warning("location service queue missing during user publish", metadata: ["error": .string("\(error)")])
                    try await store.ensureQueue(Constants.queueName)
                } else {
                    logger.warning("failed to clear existing user record", metadata: ["error": .string("\(error)")])
                }
            }
            _ = try await store.put(storedObject, into: Constants.queueName)
            logger.debug(
                "location service user index persisted",
                metadata: [
                    "user": .string(userUUID.uuidString),
                    "nodes": .array(nodeIDs.map { .string($0.uuidString) })
                ]
            )
        } catch {
            logger.error(
                "failed to publish location service user index",
                metadata: ["user": .string(userUUID.uuidString), "error": .string("\(error)")])
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
        guard let schema = object.userMetadata?["schema"], schema == Constants.nodeSchema else { return nil }
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

    func summary(staleAfter seconds: TimeInterval = 120) async -> Summary {
        let records = await snapshot()
        let generatedAt = Date()
        var staleNodes: [UUID] = []
        var userActivity: [UUID: Bool] = [:]

        for record in records {
            let lastSeenDate = Date(timeIntervalSince1970: Double(record.lastSeen) / 1000.0)
            let isStale = generatedAt.timeIntervalSince(lastSeenDate) > seconds
            if isStale {
                staleNodes.append(record.nodeUUID)
            }
            if let current = userActivity[record.userUUID] {
                userActivity[record.userUUID] = current || !isStale
            } else {
                userActivity[record.userUUID] = !isStale
            }
        }

        let sortedStaleNodes = staleNodes.sorted { $0.uuidString < $1.uuidString }
        let staleUsers = userActivity
            .filter { !$0.value }
            .map(\.key)
            .sorted { $0.uuidString < $1.uuidString }

        return Summary(
            generatedAt: generatedAt,
            totalNodes: records.count,
            totalUsers: userActivity.keys.count,
            activeNodes: records.count - sortedStaleNodes.count,
            staleNodes: sortedStaleNodes,
            staleUsers: staleUsers,
            staleThresholdSeconds: Int(seconds)
        )
    }
}
