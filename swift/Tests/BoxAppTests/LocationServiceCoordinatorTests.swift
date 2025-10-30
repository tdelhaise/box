import XCTest
import Foundation
import Logging
@testable import BoxCore
@testable import BoxServer

final class LocationServiceCoordinatorTests: XCTestCase {
    func testPublishReplacesExistingRecordAndResolvesEntries() async throws {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory.appendingPathComponent("box-ls-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let store = try await BoxServerStore(root: temporaryDirectory)
        let coordinator = LocationServiceCoordinator(store: store, logger: Logger(label: "test.location"))
        try await coordinator.bootstrap()

        let userUUID = UUID()
        let nodeUUID = UUID()
        let initialRecord = LocationServiceNodeRecord.make(
            userUUID: userUUID,
            nodeUUID: nodeUUID,
            port: 12567,
            probedGlobalIPv6: ["2001:db8::10"],
            ipv6Error: nil,
            portMappingEnabled: false,
            portMappingOrigin: .default,
            online: true,
            since: 1_000,
            lastSeen: 2_000
        )

        await coordinator.publish(record: initialRecord)

        var files = try await store.list(queue: "/whoswho")
        XCTAssertEqual(files.count, 2, "Expected node and user entries after first publish")
        let fileNames = Set(files.map { $0.url.lastPathComponent })
        XCTAssertTrue(fileNames.contains("\(nodeUUID.uuidString).json"))
        XCTAssertTrue(fileNames.contains("\(userUUID.uuidString).json"))

        let initialSnapshot = await coordinator.snapshot()
        XCTAssertEqual(initialSnapshot.count, 1)
        XCTAssertEqual(initialSnapshot.first?.nodeUUID, nodeUUID)
        XCTAssertEqual(initialSnapshot.first?.connectivity.globalIPv6, ["2001:db8::10"])
        XCTAssertEqual(initialSnapshot.first?.connectivity.portMapping.enabled, false)

        let updatedRecord = LocationServiceNodeRecord.make(
            userUUID: userUUID,
            nodeUUID: nodeUUID,
            port: 12600,
            probedGlobalIPv6: ["2001:db8::20"],
            ipv6Error: nil,
            portMappingEnabled: true,
            portMappingOrigin: .configuration,
            online: true,
            since: initialRecord.since,
            lastSeen: 3_000
        )

        await coordinator.publish(record: updatedRecord)

        files = try await store.list(queue: "/whoswho")
        XCTAssertEqual(files.count, 2, "Publishing should keep node and user entries in sync")
        let userRef = try XCTUnwrap(files.first { $0.id == userUUID })
        let userObject = try await store.read(reference: userRef)
        let decodedUserRecord = try JSONDecoder().decode(LocationServiceUserRecord.self, from: Data(userObject.data))
        XCTAssertEqual(decodedUserRecord.userUUID, userUUID)
        XCTAssertEqual(decodedUserRecord.nodeUUIDs, [nodeUUID])

        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot.first?.nodeUUID, nodeUUID)
        XCTAssertEqual(snapshot.first?.connectivity.globalIPv6, ["2001:db8::20"])
        XCTAssertEqual(snapshot.first?.connectivity.portMapping.enabled, true)
        XCTAssertEqual(snapshot.first?.connectivity.portMapping.origin, BoxRuntimeOptions.PortMappingOrigin.configuration.locationServiceValue)

        let resolvedForUser = await coordinator.resolve(userUUID: userUUID)
        XCTAssertEqual(resolvedForUser.count, 1)
        XCTAssertEqual(resolvedForUser.first?.nodeUUID, nodeUUID)

        let resolvedForNode = await coordinator.resolve(nodeUUID: nodeUUID)
        XCTAssertNotNil(resolvedForNode)
        XCTAssertEqual(resolvedForNode?.connectivity.globalIPv6, ["2001:db8::20"])
    }

    func testSummaryIdentifiesStaleNodesAndUsers() async throws {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory.appendingPathComponent("box-ls-summary-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let store = try await BoxServerStore(root: temporaryDirectory)
        let coordinator = LocationServiceCoordinator(store: store, logger: Logger(label: "test.location.summary"))
        try await coordinator.bootstrap()

        let now = Date()
        let staleUser = UUID()
        let staleNode = UUID()
        let activeUser = UUID()
        let activeNode = UUID()

        let staleLastSeen = UInt64(now.addingTimeInterval(-300).timeIntervalSince1970 * 1000)
        let activeLastSeen = UInt64(now.timeIntervalSince1970 * 1000)

        let staleRecord = LocationServiceNodeRecord.make(
            userUUID: staleUser,
            nodeUUID: staleNode,
            port: 12567,
            probedGlobalIPv6: [],
            ipv6Error: nil,
            portMappingEnabled: false,
            portMappingOrigin: .default,
            online: true,
            since: staleLastSeen,
            lastSeen: staleLastSeen
        )

        let activeRecord = LocationServiceNodeRecord.make(
            userUUID: activeUser,
            nodeUUID: activeNode,
            port: 12568,
            probedGlobalIPv6: [],
            ipv6Error: nil,
            portMappingEnabled: false,
            portMappingOrigin: .default,
            online: true,
            since: activeLastSeen,
            lastSeen: activeLastSeen
        )

        await coordinator.publish(record: staleRecord)
        await coordinator.publish(record: activeRecord)

        let summary = await coordinator.summary(staleAfter: 120)
        XCTAssertEqual(summary.totalNodes, 2)
        XCTAssertEqual(summary.totalUsers, 2)
        XCTAssertEqual(summary.activeNodes, 1)
        XCTAssertEqual(summary.staleNodes, [staleNode])
        XCTAssertEqual(summary.staleUsers, [staleUser])
        XCTAssertEqual(summary.staleThresholdSeconds, 120)
    }
}
