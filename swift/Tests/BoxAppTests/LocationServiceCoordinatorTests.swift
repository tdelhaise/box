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

        var files = try await store.list(queue: "/uuid")
        XCTAssertEqual(files.count, 1, "Expected a single presence entry after first publish")

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

        files = try await store.list(queue: "/uuid")
        XCTAssertEqual(files.count, 1, "Publishing should replace the existing entry for the node")

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
}
