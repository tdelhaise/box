import XCTest
import Foundation
import Dispatch
import Logging
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import BoxCore
@testable import BoxServer

final class BoxAdminIntegrationTests: XCTestCase {
    func testAdminPingAndLogTargetRoundTrip() async throws {
        let context = try await startServer()
        defer { context.tearDown() }

        try await context.waitForAdminSocket()
        let transport = BoxAdminTransportFactory.makeTransport(socketPath: context.socketPath)

        let pingResponse = try transport.send(command: "ping")
        let pingJSON = try decodeJSON(pingResponse)
        XCTAssertEqual(pingJSON["status"] as? String, "ok")
        XCTAssertEqual(pingJSON["message"] as? String, "pong")

        let updateResponse = try transport.send(command: "log-target stdout")
        let updateJSON = try decodeJSON(updateResponse)
        XCTAssertEqual(updateJSON["status"] as? String, "ok")
        XCTAssertEqual(updateJSON["logTarget"] as? String, "stdout")
        XCTAssertEqual(updateJSON["logTargetOrigin"] as? String, "runtime")

        let statusResponse = try transport.send(command: "status")
        let statusJSON = try decodeJSON(statusResponse)
        XCTAssertEqual(statusJSON["status"] as? String, "ok")
        XCTAssertEqual(statusJSON["logTarget"] as? String, "stdout")
        XCTAssertEqual(statusJSON["logTargetOrigin"] as? String, "runtime")
        let nodeUUIDString = statusJSON["nodeUUID"] as? String
        XCTAssertNotNil(nodeUUIDString)
        XCTAssertNotNil(nodeUUIDString.flatMap(UUID.init(uuidString:)))
        let userUUIDString = statusJSON["userUUID"] as? String
        XCTAssertNotNil(userUUIDString)
        XCTAssertNotNil(userUUIDString.flatMap(UUID.init(uuidString:)))
        let hasGlobal = (statusJSON["hasGlobalIPv6"] as? Bool) ?? (statusJSON["hasGlobalIPv6"] as? NSNumber)?.boolValue
        XCTAssertNotNil(hasGlobal)
        XCTAssertNotNil(statusJSON["globalIPv6Addresses"])
        let portMappingEnabled = (statusJSON["portMappingEnabled"] as? Bool) ?? (statusJSON["portMappingEnabled"] as? NSNumber)?.boolValue
        XCTAssertNotNil(portMappingEnabled)
        XCTAssertNotNil(statusJSON["portMappingOrigin"] as? String)
        let addresses = coerceArrayOfDictionaries(statusJSON["addresses"])
        XCTAssertNotNil(addresses)
        if let addresses {
            for address in addresses {
                XCTAssertNotNil(address["ip"] as? String)
                XCTAssertNotNil(address["port"])
                XCTAssertNotNil(address["scope"] as? String)
                XCTAssertNotNil(address["source"] as? String)
            }
        }
        if let connectivity = coerceDictionary(statusJSON["connectivity"]) {
            XCTAssertNotNil(connectivity["hasGlobalIPv6"])
            XCTAssertNotNil(connectivity["globalIPv6"])
            let portMapping = coerceDictionary(connectivity["portMapping"])
            XCTAssertNotNil(portMapping)
            XCTAssertNotNil(portMapping?["origin"] as? String)
            XCTAssertNotNil(portMapping?["enabled"])
        } else {
            XCTFail("connectivity payload missing from status response")
        }
        let queueCount = (statusJSON["queueCount"] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThanOrEqual(queueCount, 1)
        XCTAssertNotNil(statusJSON["objects"] as? NSNumber)
        XCTAssertEqual(statusJSON["queueRoot"] as? String, context.homeDirectory.appendingPathComponent(".box/queues").path)
        XCTAssertNotNil(statusJSON["queueFreeBytes"] as? NSNumber)
    }

    func testReloadConfigUpdatesLogLevel() async throws {
        let context = try await startServer()
        defer { context.tearDown() }

        try await context.waitForAdminSocket()
        let transport = BoxAdminTransportFactory.makeTransport(socketPath: context.socketPath)

        let configurationResult = try BoxConfiguration.load(from: context.configurationURL)
        var configuration = configurationResult.configuration
        configuration.server.logLevel = .debug
        try configuration.save(to: context.configurationURL)

        let reloadResponse = try transport.send(command: "reload-config {\"path\":\"\(context.configurationURL.path)\"}")
        let reloadJSON = try decodeJSON(reloadResponse)
        XCTAssertEqual(reloadJSON["status"] as? String, "ok")
        XCTAssertEqual(reloadJSON["logLevel"] as? String, "debug")
        XCTAssertEqual(reloadJSON["logLevelOrigin"] as? String, "configuration")
        let reloadedNodeUUID = reloadJSON["nodeUUID"] as? String
        XCTAssertNotNil(reloadedNodeUUID)
        XCTAssertEqual(reloadJSON["userUUID"] as? String, configuration.common.userUUID.uuidString)
        XCTAssertNotNil(reloadJSON["hasGlobalIPv6"])
        XCTAssertNotNil(reloadJSON["portMappingEnabled"])
        XCTAssertNotNil(coerceArrayOfDictionaries(reloadJSON["addresses"]))
        XCTAssertNotNil(coerceDictionary(reloadJSON["connectivity"]))

        let statsResponse = try transport.send(command: "stats")
        let statsJSON = try decodeJSON(statsResponse)
        XCTAssertEqual(statsJSON["logLevel"] as? String, "debug")
        XCTAssertEqual(statsJSON["logLevelOrigin"] as? String, "configuration")
        let statsQueueCount = (statsJSON["queueCount"] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThanOrEqual(statsQueueCount, 1)
        XCTAssertNotNil(statsJSON["objects"] as? NSNumber)
        XCTAssertNotNil(statsJSON["queueFreeBytes"] as? NSNumber)
        XCTAssertNotNil(statsJSON["hasGlobalIPv6"])
        XCTAssertNotNil(statsJSON["portMappingEnabled"])
        XCTAssertNotNil(coerceArrayOfDictionaries(statsJSON["addresses"]))
        XCTAssertNotNil(coerceDictionary(statsJSON["connectivity"]))

        let verificationLogger = Logger(label: "box.integration.reload")
        XCTAssertEqual(verificationLogger.logLevel, .debug)

        let statusAfter = try decodeJSON(try transport.send(command: "status"))
        let statusNodeUUID = statusAfter["nodeUUID"] as? String
        XCTAssertEqual(statusAfter["logLevel"] as? String, "debug")
        XCTAssertEqual(statusNodeUUID, reloadedNodeUUID)
        XCTAssertNotNil(statusNodeUUID.flatMap(UUID.init(uuidString:)))
        XCTAssertEqual(statusAfter["userUUID"] as? String, configuration.common.userUUID.uuidString)
        XCTAssertNotNil(statusAfter["hasGlobalIPv6"])
        XCTAssertNotNil(statusAfter["portMappingEnabled"])
        let statusAfterQueueCount = (statusAfter["queueCount"] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThanOrEqual(statusAfterQueueCount, 1)
        XCTAssertEqual(statusAfter["queueRoot"] as? String, context.homeDirectory.appendingPathComponent(".box/queues").path)
        XCTAssertNotNil(statusAfter["queueFreeBytes"] as? NSNumber)
        XCTAssertNotNil(coerceArrayOfDictionaries(statusAfter["addresses"]))
        XCTAssertNotNil(coerceDictionary(statusAfter["connectivity"]))
    }

    func testAdminLocateReturnsServerRecord() async throws {
        let context = try await startServer()
        defer { context.tearDown() }

        try await context.waitForAdminSocket()
        let transport = BoxAdminTransportFactory.makeTransport(socketPath: context.socketPath)

        let statusJSON = try decodeJSON(try transport.send(command: "status"))
        let nodeUUID = try XCTUnwrap(statusJSON["nodeUUID"] as? String)

        let locateJSON = try decodeJSON(try transport.send(command: "locate \(nodeUUID)"))
        XCTAssertEqual(locateJSON["status"] as? String, "ok")
        let record = try XCTUnwrap(coerceDictionary(locateJSON["record"]))
        XCTAssertEqual(record["nodeUUID"] as? String, nodeUUID)
        XCTAssertEqual(record["userUUID"] as? String, statusJSON["userUUID"] as? String)
        XCTAssertNotNil(coerceArrayOfDictionaries(record["addresses"]))
        XCTAssertNotNil(coerceDictionary(record["connectivity"]))

        let userUUID = try XCTUnwrap(statusJSON["userUUID"] as? String)
        let locateUserJSON = try decodeJSON(try transport.send(command: "locate \(userUUID)"))
        XCTAssertEqual(locateUserJSON["status"] as? String, "ok")
        let userPayload = try XCTUnwrap(coerceDictionary(locateUserJSON["user"]))
        XCTAssertEqual(userPayload["userUUID"] as? String, userUUID)
        let nodeUUIDs = (userPayload["nodeUUIDs"] as? [String]) ?? (userPayload["nodeUUIDs"] as? [NSString])?.map { $0 as String }
        XCTAssertEqual(nodeUUIDs, [nodeUUID])
        let userRecords = try XCTUnwrap(coerceArrayOfDictionaries(userPayload["records"]))
        XCTAssertEqual(userRecords.count, 1)
        XCTAssertEqual(userRecords.first?["nodeUUID"] as? String, nodeUUID)

        let missingJSON = try decodeJSON(try transport.send(command: "locate \(UUID().uuidString)"))
        XCTAssertEqual(missingJSON["status"] as? String, "error")
        XCTAssertEqual(missingJSON["message"] as? String, "node-not-found")
    }
}

// MARK: - Helpers

private func decodeJSON(_ response: String) throws -> [String: Any] {
    let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = trimmed.data(using: .utf8) else {
        throw NSError(domain: "BoxAdminIntegrationTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "response is not UTF-8"])
    }
    let object = try JSONSerialization.jsonObject(with: data, options: [])
    guard let dictionary = object as? [String: Any] else {
        throw NSError(domain: "BoxAdminIntegrationTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "response is not a JSON object"])
    }
    return dictionary
}

/// Converts an arbitrary JSON object into a Swift dictionary when possible.
/// - Parameter value: The value returned by `JSONSerialization`.
/// - Returns: A `[String: Any]` representation when the value is bridgeable.
private func coerceDictionary(_ value: Any?) -> [String: Any]? {
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

/// Converts an arbitrary JSON array into an array of dictionaries when possible.
/// - Parameter value: The value returned by `JSONSerialization`.
/// - Returns: An array of `[String: Any]` dictionaries when every element is bridgeable.
private func coerceArrayOfDictionaries(_ value: Any?) -> [[String: Any]]? {
    if let array = value as? [[String: Any]] {
        return array
    }
    if let nsArray = value as? [NSDictionary] {
        return nsArray.compactMap { dictionary in
            coerceDictionary(dictionary)
        }
    }
    if let genericArray = value as? [Any] {
        var result: [[String: Any]] = []
        for element in genericArray {
            guard let dictionary = coerceDictionary(element) else {
                return nil
            }
            result.append(dictionary)
        }
        return result
    }
    return nil
}
