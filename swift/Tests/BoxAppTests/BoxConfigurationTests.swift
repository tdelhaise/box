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
            "admin_channel": false
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
    }
}
