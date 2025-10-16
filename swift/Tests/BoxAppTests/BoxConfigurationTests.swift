import BoxCore
import Foundation
import Logging
import XCTest

final class BoxConfigurationTests: XCTestCase {
    func testLoadServerConfigurationFromPlist() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let plistURL = temporaryDirectory.appendingPathComponent("boxd.plist")
        let propertyList: [String: Any] = [
            "port": 15000,
            "log_level": "debug",
            "log_target": "stdout",
            "transport": "noise",
            "pre_share_key": "secret",
            "admin_channel": false,
            "node_uuid": UUID().uuidString
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: propertyList, format: .xml, options: 0)
        try data.write(to: plistURL)

        let configuration = try BoxServerConfiguration.load(from: plistURL)
        XCTAssertEqual(configuration?.port, 15000)
        XCTAssertEqual(configuration?.logLevel, Logger.Level.debug)
        XCTAssertEqual(configuration?.logTarget, "stdout")
        XCTAssertEqual(configuration?.transportGeneral, "noise")
        XCTAssertEqual(configuration?.preShareKey, "secret")
        XCTAssertEqual(configuration?.adminChannelEnabled, false)
        XCTAssertNotNil(configuration?.nodeUUID)
    }

    func testLoadClientConfigurationFromPlist() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let plistURL = temporaryDirectory.appendingPathComponent("box.plist")
        let propertyList: [String: Any] = [
            "log_level": "error",
            "log_target": "file:/tmp/box.log",
            "address": "192.0.2.42",
            "port": 18000,
            "node_uuid": UUID().uuidString
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: propertyList, format: .xml, options: 0)
        try data.write(to: plistURL)

        let configuration = try BoxClientConfiguration.load(from: plistURL)
        XCTAssertEqual(configuration?.logLevel, Logger.Level.error)
        XCTAssertEqual(configuration?.logTarget, "file:/tmp/box.log")
        XCTAssertEqual(configuration?.address, "192.0.2.42")
        XCTAssertEqual(configuration?.port, 18000)
        XCTAssertNotNil(configuration?.nodeUUID)
    }

    func testServerConfigurationCreatesDefaultWhenMissing() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let plistURL = temporaryDirectory.appendingPathComponent("boxd.plist")
        XCTAssertFalse(FileManager.default.fileExists(atPath: plistURL.path))

        let configuration = try BoxServerConfiguration.load(from: plistURL)
        XCTAssertNotNil(configuration)
        XCTAssertEqual(configuration?.logLevel, .info)
        XCTAssertEqual(configuration?.logTarget, "stderr")
        XCTAssertEqual(configuration?.adminChannelEnabled, true)
        XCTAssertNotNil(configuration?.nodeUUID)

        let contents = try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), options: [], format: nil) as? [String: Any]
        XCTAssertNotNil(contents?["node_uuid"] as? String)
    }

    func testClientConfigurationCreatesDefaultWhenMissing() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let plistURL = temporaryDirectory.appendingPathComponent("box.plist")
        XCTAssertFalse(FileManager.default.fileExists(atPath: plistURL.path))

        let configuration = try BoxClientConfiguration.load(from: plistURL)
        XCTAssertNotNil(configuration)
        XCTAssertEqual(configuration?.logLevel, .info)
        XCTAssertEqual(configuration?.logTarget, "stderr")
        XCTAssertEqual(configuration?.address, BoxRuntimeOptions.defaultClientAddress)
        XCTAssertEqual(configuration?.port, BoxRuntimeOptions.defaultPort)
        XCTAssertNotNil(configuration?.nodeUUID)

        let contents = try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), options: [], format: nil) as? [String: Any]
        XCTAssertNotNil(contents?["node_uuid"] as? String)
    }
}
