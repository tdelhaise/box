import Foundation
import XCTest
@testable import BoxCore

/// Tests covering the Location Service data model helpers.
final class LocationServiceModelsTests: XCTestCase {
    func testMakeProducesDeterministicRecord() throws {
        let userUUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let nodeUUID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let additional = LocationServiceNodeRecord.Address(
            ip: "192.0.2.10",
            port: 12567,
            scope: .lan,
            source: .config
        )

        let record = LocationServiceNodeRecord.make(
            userUUID: userUUID,
            nodeUUID: nodeUUID,
            port: 12567,
            probedGlobalIPv6: ["2001:db8::10"],
            ipv6Error: nil,
            portMappingEnabled: true,
            portMappingOrigin: .cliFlag,
            additionalAddresses: [additional],
            online: true,
            since: 1,
            lastSeen: 2,
            nodePublicKey: "ed25519:abcd",
            tags: ["role": "primary"]
        )

        XCTAssertEqual(record.userUUID, userUUID)
        XCTAssertEqual(record.nodeUUID, nodeUUID)
        XCTAssertEqual(Set(record.addresses), Set([additional, LocationServiceNodeRecord.Address(ip: "2001:db8::10", port: 12567, scope: .global, source: .probe)]))
        XCTAssertTrue(record.connectivity.hasGlobalIPv6)
        XCTAssertEqual(record.connectivity.globalIPv6, ["2001:db8::10"])
        XCTAssertNil(record.connectivity.ipv6ProbeError)
        XCTAssertTrue(record.connectivity.portMapping.enabled)
        XCTAssertEqual(record.connectivity.portMapping.origin, "cli")
        XCTAssertEqual(record.since, 1)
        XCTAssertEqual(record.lastSeen, 2)
        XCTAssertEqual(record.tags?["role"], "primary")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        guard let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("encoded record is not a dictionary")
            return
        }
        XCTAssertEqual((jsonObject["user_uuid"] as? String)?.lowercased(), userUUID.uuidString.lowercased())
        XCTAssertEqual((jsonObject["node_uuid"] as? String)?.lowercased(), nodeUUID.uuidString.lowercased())
        let addresses = unwrapArrayOfDictionaries(jsonObject["addresses"])
        XCTAssertEqual(addresses?.count, 2)
        if let first = addresses?.first {
            XCTAssertNotNil(first["ip"] as? String)
            XCTAssertNotNil(first["scope"] as? String)
            XCTAssertNotNil(first["source"] as? String)
        }
        let connectivity = unwrapDictionary(jsonObject["connectivity"])
        XCTAssertNotNil(connectivity?["has_global_ipv6"])
        let portMapping = unwrapDictionary(connectivity?["port_mapping"])
        XCTAssertEqual(portMapping?["origin"] as? String, "cli")
        XCTAssertEqual(portMapping?["enabled"] as? Bool, true)
    }
}

/// Helper that coerces a JSON value to a dictionary.
/// - Parameter value: Raw value produced by `JSONSerialization`.
/// - Returns: A Swift dictionary when the value is bridgeable.
private func unwrapDictionary(_ value: Any?) -> [String: Any]? {
    if let dictionary = value as? [String: Any] {
        return dictionary
    }
    if let nsDictionary = value as? NSDictionary {
        var result: [String: Any] = [:]
        for case let (key as String, element) in nsDictionary {
            result[key] = element
        }
        return result
    }
    return nil
}

/// Helper that coerces a JSON value to an array of dictionaries.
/// - Parameter value: Raw value produced by `JSONSerialization`.
/// - Returns: An array of dictionaries when bridgeable.
private func unwrapArrayOfDictionaries(_ value: Any?) -> [[String: Any]]? {
    if let array = value as? [[String: Any]] {
        return array
    }
    if let nsArray = value as? [NSDictionary] {
        return nsArray.compactMap { unwrapDictionary($0) }
    }
    if let genericArray = value as? [Any] {
        var result: [[String: Any]] = []
        for element in genericArray {
            guard let dictionary = unwrapDictionary(element) else {
                return nil
            }
            result.append(dictionary)
        }
        return result
    }
    return nil
}
