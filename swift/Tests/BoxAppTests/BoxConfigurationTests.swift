import BoxCore
import Foundation
import Logging
import XCTest

final class BoxConfigurationTests: XCTestCase {
    func testLoadConfigurationWithSections() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let plistURL = temporaryDirectory.appendingPathComponent("Box.plist")
        let nodeIdentifier = UUID()
        let userIdentifier = UUID()
        let propertyList: [String: Any] = [
            "common": [
                "node_uuid": nodeIdentifier.uuidString,
                "user_uuid": userIdentifier.uuidString
            ],
            "server": [
                "port": 15000,
                "log_level": "debug",
                "log_target": "stdout",
                "transport": "noise",
                "pre_share_key": "secret",
                "admin_channel": false
            ],
            "client": [
                "log_level": "error",
                "log_target": "file:/tmp/box.log",
                "address": "192.0.2.42",
                "port": 18000
            ]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: propertyList, format: .xml, options: 0)
        try data.write(to: plistURL)

        let result = try BoxConfiguration.load(from: plistURL)
        XCTAssertFalse(result.wasCreated)

        let configuration = result.configuration
        XCTAssertEqual(configuration.common.nodeUUID, nodeIdentifier)
        XCTAssertEqual(configuration.common.userUUID, userIdentifier)

        XCTAssertEqual(configuration.server.port, 15000)
        XCTAssertEqual(configuration.server.logLevel, Logger.Level.debug)
        XCTAssertEqual(configuration.server.logTarget, "stdout")
        XCTAssertEqual(configuration.server.transportGeneral, "noise")
        XCTAssertEqual(configuration.server.preShareKey, "secret")
        XCTAssertEqual(configuration.server.adminChannelEnabled, false)

        XCTAssertEqual(configuration.client.logLevel, Logger.Level.error)
        XCTAssertEqual(configuration.client.logTarget, "file:/tmp/box.log")
        XCTAssertEqual(configuration.client.address, "192.0.2.42")
        XCTAssertEqual(configuration.client.port, 18000)
    }

    func testCreatesDefaultWhenMissing() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let plistURL = temporaryDirectory.appendingPathComponent("Box.plist")
        XCTAssertFalse(FileManager.default.fileExists(atPath: plistURL.path))

        let result = try BoxConfiguration.load(from: plistURL)
        XCTAssertTrue(result.wasCreated)

        let configuration = result.configuration
        XCTAssertNotNil(configuration.common.nodeUUID)
        XCTAssertNotNil(configuration.common.userUUID)

        XCTAssertEqual(configuration.server.logLevel, .info)
        XCTAssertEqual(configuration.server.logTarget, "stderr")
        XCTAssertEqual(configuration.server.adminChannelEnabled, true)
        XCTAssertEqual(configuration.server.port, BoxRuntimeOptions.defaultPort)

        XCTAssertEqual(configuration.client.logLevel, .info)
        XCTAssertEqual(configuration.client.logTarget, "stderr")
        XCTAssertEqual(configuration.client.address, BoxRuntimeOptions.defaultClientAddress)
        XCTAssertEqual(configuration.client.port, BoxRuntimeOptions.defaultPort)

        let contents = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: plistURL),
            options: [],
            format: nil
        ) as? [String: Any]
        let common = contents?["common"] as? [String: Any]
        XCTAssertNotNil(common?["node_uuid"] as? String)
        XCTAssertNotNil(common?["user_uuid"] as? String)
        XCTAssertNotNil(contents?["server"] as? [String: Any])
        XCTAssertNotNil(contents?["client"] as? [String: Any])
    }

    func testRepairsMissingSections() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let plistURL = temporaryDirectory.appendingPathComponent("Box.plist")
        let propertyList: [String: Any] = [
            "server": [
                "log_level": "trace"
            ]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: propertyList, format: .xml, options: 0)
        try data.write(to: plistURL)

        let result = try BoxConfiguration.load(from: plistURL)
        XCTAssertFalse(result.wasCreated)

        let configuration = result.configuration
        XCTAssertEqual(configuration.server.logLevel, .trace)
        XCTAssertEqual(configuration.client.logLevel, .info)
        XCTAssertNotNil(configuration.common.nodeUUID)
        XCTAssertNotNil(configuration.common.userUUID)

        let persisted = try Data(contentsOf: plistURL)
        let updatedPlist = try PropertyListSerialization.propertyList(from: persisted, options: [], format: nil) as? [String: Any]
        let common = updatedPlist?["common"] as? [String: Any]
        XCTAssertNotNil(common?["node_uuid"] as? String)
        XCTAssertNotNil(common?["user_uuid"] as? String)
        XCTAssertNotNil(updatedPlist?["client"] as? [String: Any])
    }
}
