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
                "user_uuid": userIdentifier.uuidString,
                "root_servers": [
                    ["address": "2001:db8::5", "port": 17500],
                    ["address": "198.51.100.42"]
                ]
            ],
            "server": [
            "port": 15000,
            "log_level": "debug",
            "log_target": "stdout",
            "transport": "noise",
            "pre_share_key": "secret",
            "admin_channel": false,
            "port_mapping": true,
            "external_address": "198.51.100.4",
            "external_port": 16000,
            "permanent_queues": ["INBOX", "alerts"]
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
        XCTAssertEqual(configuration.common.rootServers.count, 2)
        XCTAssertEqual(configuration.common.rootServers[0].address, "2001:db8::5")
        XCTAssertEqual(configuration.common.rootServers[0].port, 17500)
        XCTAssertEqual(configuration.common.rootServers[1].address, "198.51.100.42")
        XCTAssertEqual(configuration.common.rootServers[1].port, BoxRuntimeOptions.defaultPort)

        XCTAssertEqual(configuration.server.port, 15000)
        XCTAssertEqual(configuration.server.logLevel, Logger.Level.debug)
        XCTAssertEqual(configuration.server.logTarget, "stdout")
        XCTAssertEqual(configuration.server.transportGeneral, "noise")
        XCTAssertEqual(configuration.server.preShareKey, "secret")
        XCTAssertEqual(configuration.server.adminChannelEnabled, false)
        XCTAssertEqual(configuration.server.portMappingEnabled, true)
        XCTAssertEqual(configuration.server.externalAddress, "198.51.100.4")
        XCTAssertEqual(configuration.server.externalPort, 16000)
        XCTAssertEqual(configuration.server.permanentQueues ?? [], ["INBOX", "alerts"])

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
        XCTAssertEqual(configuration.common.rootServers, [])

        XCTAssertEqual(configuration.server.logLevel, .info)
        let expectedServerTarget: String = {
            switch BoxRuntimeOptions.defaultLogTarget(for: .server) {
            case .stderr:
                return "stderr"
            case .stdout:
                return "stdout"
            case .file(let path):
                return "file:\(path)"
            }
        }()
        XCTAssertEqual(configuration.server.logTarget, expectedServerTarget)
        XCTAssertEqual(configuration.server.adminChannelEnabled, true)
        XCTAssertEqual(configuration.server.port, BoxRuntimeOptions.defaultPort)
        XCTAssertEqual(configuration.server.portMappingEnabled ?? false, false)
        XCTAssertNil(configuration.server.externalAddress)
        XCTAssertNil(configuration.server.externalPort)
        XCTAssertEqual(configuration.server.permanentQueues ?? [], [])
        XCTAssertEqual(configuration.common.rootServers, [])
        XCTAssertEqual(configuration.server.permanentQueues ?? [], [])

        XCTAssertEqual(configuration.client.logLevel, .info)
        let expectedClientTarget: String = {
            switch BoxRuntimeOptions.defaultLogTarget(for: .client) {
            case .stderr:
                return "stderr"
            case .stdout:
                return "stdout"
            case .file(let path):
                return "file:\(path)"
            }
        }()
        XCTAssertEqual(configuration.client.logTarget, expectedClientTarget)
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
        XCTAssertNotNil(common?["root_servers"] as? [Any])
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
        XCTAssertEqual(configuration.server.portMappingEnabled ?? false, false)
        XCTAssertNil(configuration.server.externalAddress)
        XCTAssertNil(configuration.server.externalPort)
        XCTAssertEqual(configuration.server.permanentQueues ?? [], [])
        XCTAssertEqual(configuration.common.rootServers, [])

        let persisted = try Data(contentsOf: plistURL)
        let updatedPlist = try PropertyListSerialization.propertyList(from: persisted, options: [], format: nil) as? [String: Any]
        let common = updatedPlist?["common"] as? [String: Any]
        XCTAssertNotNil(common?["node_uuid"] as? String)
        XCTAssertNotNil(common?["user_uuid"] as? String)
        XCTAssertNotNil(common?["root_servers"] as? [Any])
        XCTAssertNotNil(updatedPlist?["client"] as? [String: Any])
        let serverSection = updatedPlist?["server"] as? [String: Any]
        XCTAssertNotNil(serverSection?["permanent_queues"] as? [Any])
    }

    func testSanitisesRootServerEntries() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let plistURL = temporaryDirectory.appendingPathComponent("Box.plist")
        let propertyList: [String: Any] = [
            "common": [
                "node_uuid": UUID().uuidString,
                "user_uuid": UUID().uuidString,
                "root_servers": [
                    ["address": "  resolver.box.local  ", "port": 18000],
                    ["address": ""],
                    [:]
                ]
            ]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: propertyList, format: .xml, options: 0)
        try data.write(to: plistURL)

        let result = try BoxConfiguration.load(from: plistURL)
        let rootServers = result.configuration.common.rootServers
        XCTAssertEqual(rootServers.count, 1)
        XCTAssertEqual(rootServers.first?.address, "resolver.box.local")
        XCTAssertEqual(rootServers.first?.port, 18000)

        let persisted = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: plistURL),
            options: [],
            format: nil
        ) as? [String: Any]
        let common = persisted?["common"] as? [String: Any]
        let storedRoots = common?["root_servers"] as? [[String: Any]]
        XCTAssertEqual(storedRoots?.count, 1)
        XCTAssertEqual(storedRoots?.first?["address"] as? String, "resolver.box.local")
        XCTAssertEqual(storedRoots?.first?["port"] as? Int, 18000)
    }
}
