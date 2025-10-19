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

final class BoxCLIIntegrationTests: XCTestCase {

    func testAdminPingCLI() async throws {
        let context = try await startServer()
        defer { context.tearDown() }

        try await context.waitForAdminSocket()

        let (stdout, stderr, status) = try runBoxCLI(args: ["admin", "ping", "--socket", context.socketPath])
        XCTAssertEqual(status, 0)
        XCTAssertTrue(stderr.isEmpty)

        let json = try decodeJSON(stdout)
        XCTAssertEqual(json["status"] as? String, "ok")
        XCTAssertEqual(json["message"] as? String, "pong")
    }

    func testAdminStatusCLI() async throws {
        let context = try await startServer()
        defer { context.tearDown() }

        try await context.waitForAdminSocket()

        let (stdout, stderr, status) = try runBoxCLI(args: ["admin", "status", "--socket", context.socketPath])
        XCTAssertEqual(status, 0)
        XCTAssertTrue(stderr.isEmpty)

        let json = try decodeJSON(stdout)
        XCTAssertEqual(json["status"] as? String, "ok")
        XCTAssertNotNil(json["nodeUUID"])
        XCTAssertNotNil(json["userUUID"])
    }

    // Helper to run the box CLI tool
    private func runBoxCLI(args: [String]) throws -> (String, String, Int32) {
        let boxBinary = productsDirectory.appendingPathComponent("box")

        let process = Process()
        process.executableURL = boxBinary
        process.arguments = args

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        let errorPipe = Pipe()
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        let error = String(data: errorData, encoding: .utf8) ?? ""

        return (output, error, process.terminationStatus)
    }

    /// Returns path to the built products directory.
    var productsDirectory: URL {
      #if os(macOS)
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            return bundle.bundleURL.deletingLastPathComponent()
        }
        fatalError("couldn\'t find the products directory")
      #else
        return Bundle.main.bundleURL
      #endif
    }
}

private func decodeJSON(_ response: String) throws -> [String: Any] {
    let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = trimmed.data(using: .utf8) else {
        throw NSError(domain: "BoxCLIIntegrationTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "response is not UTF-8"])
    }
    let object = try JSONSerialization.jsonObject(with: data, options: [])
    guard let dictionary = object as? [String: Any] else {
        throw NSError(domain: "BoxCLIIntegrationTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "response is not a JSON object"])
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
        return nsArray.compactMap {
            coerceDictionary($0)
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