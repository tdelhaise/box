import XCTest
@testable import BoxCore
@testable import BoxServer

final class BoxAdminDispatcherTests: XCTestCase {
    func testStatusCommandInvokesProvider() async throws {
        let expectation = expectation(description: "status provider")
        let dispatcher = BoxAdminCommandDispatcher(
            statusProvider: {
                expectation.fulfill()
                return "{\"status\":\"ok\"}"
            },
            logTargetUpdater: { _ in
                XCTFail("log target should not be called")
                return ""
            },
            reloadConfiguration: { _ in
                XCTFail("reload config should not be called")
                return ""
            },
            statsProvider: {
                XCTFail("stats should not be called")
                return ""
            },
            locateNode: { _ in "" },
            natProbe: { _ in "" },
            locationSummaryProvider: { "" },
            syncRoots: {
                XCTFail("sync-roots should not be called")
                return ""
            }
        )

        let response = await dispatcher.process("status")
        XCTAssertEqual(response, "{\"status\":\"ok\"}")
        await fulfillment(of: [expectation], timeout: 0.1)
    }

    func testPingReturnsPong() async throws {
        let dispatcher = fixtureDispatcher()
        let response = await dispatcher.process("ping")
        let data = response.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8)
        let json = try XCTUnwrap(data.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertEqual(json["status"] as? String, "ok")
        let message = try XCTUnwrap(json["message"] as? String)
        XCTAssertTrue(message.hasPrefix("pong"))
        XCTAssertTrue(message.contains(BoxVersionInfo.version), "Expected message to contain version, got: \(message)")
    }

    func testLogTargetAcceptsPlainArgument() async throws {
        let expectation = expectation(description: "log-target plain")
        let capture = CaptureBox<String>()
        let dispatcher = BoxAdminCommandDispatcher(
            statusProvider: { "" },
            logTargetUpdater: { target in
                capture.value = target
                expectation.fulfill()
                return "{\"status\":\"ok\"}"
            },
            reloadConfiguration: { _ in "" },
            statsProvider: { "" },
            locateNode: { _ in "" },
            natProbe: { _ in "" },
            locationSummaryProvider: { "" },
            syncRoots: { "" }
        )

        let response = await dispatcher.process("log-target stdout")
        XCTAssertEqual(response, "{\"status\":\"ok\"}")
        await fulfillment(of: [expectation], timeout: 0.1)
        XCTAssertEqual(capture.value, "stdout")
    }

    func testLogTargetAcceptsJSONPayload() async throws {
        let expectation = expectation(description: "log-target json")
        let dispatcher = BoxAdminCommandDispatcher(
            statusProvider: { "" },
            logTargetUpdater: { target in
                XCTAssertEqual(target, "stderr")
                expectation.fulfill()
                return "ack"
            },
            reloadConfiguration: { _ in "" },
            statsProvider: { "" },
            locateNode: { _ in "" },
            natProbe: { _ in "" },
            locationSummaryProvider: { "" },
            syncRoots: { "" }
        )

        let response = await dispatcher.process("log-target {\"target\":\"stderr\"}")
        XCTAssertEqual(response, "ack")
        await fulfillment(of: [expectation], timeout: 0.1)
    }

    func testReloadConfigAcceptsOptionalPath() async throws {
        let expectation = expectation(description: "reload-config path")
        let capture = CaptureBox<String>()
        let dispatcher = BoxAdminCommandDispatcher(
            statusProvider: { "" },
            logTargetUpdater: { _ in "" },
            reloadConfiguration: { path in
                capture.value = path
                expectation.fulfill()
                return "ok"
            },
            statsProvider: { "" },
            locateNode: { _ in "" },
            natProbe: { _ in "" },
            locationSummaryProvider: { "" },
            syncRoots: { "" }
        )

        let response = await dispatcher.process("reload-config {\"path\":\"~/config.plist\"}")
        XCTAssertEqual(response, "ok")
        await fulfillment(of: [expectation], timeout: 0.1)
        XCTAssertEqual(capture.value, "~/config.plist")
    }

    func testUnknownCommandReturnsError() async {
        let dispatcher = fixtureDispatcher()
        let response = await dispatcher.process("unknown-cmd")
        assertJSON(response, equals: ["status": "error", "message": "unknown-command", "command": "unknown-cmd"])
    }

    func testEmptyCommandReportsError() async {
        let dispatcher = fixtureDispatcher()
        let response = await dispatcher.process("   \n")
        assertJSON(response, equals: ["status": "error", "message": "empty-command"])
    }

    func testInvalidLogTargetPayloadReportsError() async {
        let dispatcher = fixtureDispatcher()
        let response = await dispatcher.process("log-target {\"unexpected\":42}")
        assertJSON(response, equals: ["status": "error", "message": "invalid-log-target-payload"])
    }

    func testStatsCommandInvokesProvider() async throws {
        let expectation = expectation(description: "stats provider")
        let dispatcher = BoxAdminCommandDispatcher(
            statusProvider: { "" },
            logTargetUpdater: { _ in "" },
            reloadConfiguration: { _ in "" },
            statsProvider: {
                expectation.fulfill()
                return "{\"status\":\"ok\"}"
            },
            locateNode: { _ in "" },
            natProbe: { _ in "" },
            locationSummaryProvider: { "" },
            syncRoots: { "" }
        )

        let response = await dispatcher.process("stats")
        XCTAssertEqual(response, "{\"status\":\"ok\"}")
        await fulfillment(of: [expectation], timeout: 0.1)
    }

    func testNatProbeInvokesClosure() async throws {
        let expectation = expectation(description: "nat probe closure")
        let dispatcher = BoxAdminCommandDispatcher(
            statusProvider: { "" },
            logTargetUpdater: { _ in "" },
            reloadConfiguration: { _ in "" },
            statsProvider: { "" },
            locateNode: { _ in "" },
            natProbe: { gateway in
                expectation.fulfill()
                XCTAssertEqual(gateway, "192.0.2.1")
                return "{\"status\":\"ok\"}"
            },
            locationSummaryProvider: { "" },
            syncRoots: { "" }
        )

        let response = await dispatcher.process("nat-probe 192.0.2.1")
        XCTAssertEqual(response, "{\"status\":\"ok\"}")
        await fulfillment(of: [expectation], timeout: 0.1)
    }

    func testLocationSummaryInvokesProvider() async throws {
        let expectation = expectation(description: "location summary provider")
        let dispatcher = BoxAdminCommandDispatcher(
            statusProvider: { "" },
            logTargetUpdater: { _ in "" },
            reloadConfiguration: { _ in "" },
            statsProvider: { "" },
            locateNode: { _ in "" },
            natProbe: { _ in "" },
            locationSummaryProvider: {
                expectation.fulfill()
                return "{\"status\":\"ok\"}"
            },
            syncRoots: { "" }
        )

        let response = await dispatcher.process("location-summary")
        XCTAssertEqual(response, "{\"status\":\"ok\"}")
        await fulfillment(of: [expectation], timeout: 0.1)
    }

    private func fixtureDispatcher() -> BoxAdminCommandDispatcher {
        BoxAdminCommandDispatcher(
            statusProvider: { "status" },
            logTargetUpdater: { _ in "log" },
            reloadConfiguration: { _ in "reload" },
            statsProvider: { "stats" },
            locateNode: { _ in "locate" },
            natProbe: { _ in "probe" },
            locationSummaryProvider: { "summary" },
            syncRoots: { "sync" }
        )
    }
}

/// Simple reference wrapper used to capture values inside `@Sendable` closures during testing.
final class CaptureBox<Value>: @unchecked Sendable {
    var value: Value?
}

private func assertJSON(_ string: String, equals expected: [String: String], file: StaticString = #filePath, line: UInt = #line) {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = trimmed.data(using: .utf8) else {
        XCTFail("response is not UTF-8", file: file, line: line)
        return
    }
    do {
        guard let dictionary = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            XCTFail("response is not a JSON object", file: file, line: line)
            return
        }
        var converted: [String: String] = [:]
        for (key, value) in dictionary {
            converted[key] = "\(value)"
        }
        XCTAssertEqual(converted, expected, file: file, line: line)
    } catch {
        XCTFail("failed to decode JSON: \(error)", file: file, line: line)
    }
}
