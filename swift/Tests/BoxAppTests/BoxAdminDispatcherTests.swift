import XCTest
@testable import BoxServer

final class BoxAdminDispatcherTests: XCTestCase {
    func testStatusCommandInvokesProvider() {
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
            }
        )

        let response = dispatcher.process("status")
        XCTAssertEqual(response, "{\"status\":\"ok\"}")
        wait(for: [expectation], timeout: 0.1)
    }

    func testPingReturnsPong() {
        let dispatcher = fixtureDispatcher()
        let response = dispatcher.process("ping")
        assertJSON(response, equals: ["status": "ok", "message": "pong"])
    }

    func testLogTargetAcceptsPlainArgument() {
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
            statsProvider: { "" }
        )

        let response = dispatcher.process("log-target stdout")
        XCTAssertEqual(response, "{\"status\":\"ok\"}")
        wait(for: [expectation], timeout: 0.1)
        XCTAssertEqual(capture.value, "stdout")
    }

    func testLogTargetAcceptsJSONPayload() {
        let expectation = expectation(description: "log-target json")
        let dispatcher = BoxAdminCommandDispatcher(
            statusProvider: { "" },
            logTargetUpdater: { target in
                XCTAssertEqual(target, "stderr")
                expectation.fulfill()
                return "ack"
            },
            reloadConfiguration: { _ in "" },
            statsProvider: { "" }
        )

        let response = dispatcher.process("log-target {\"target\":\"stderr\"}")
        XCTAssertEqual(response, "ack")
        wait(for: [expectation], timeout: 0.1)
    }

    func testReloadConfigAcceptsOptionalPath() {
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
            statsProvider: { "" }
        )

        let response = dispatcher.process("reload-config {\"path\":\"~/config.plist\"}")
        XCTAssertEqual(response, "ok")
        wait(for: [expectation], timeout: 0.1)
        XCTAssertEqual(capture.value, "~/config.plist")
    }

    func testUnknownCommandReturnsError() {
        let dispatcher = fixtureDispatcher()
        let response = dispatcher.process("unknown-cmd")
        assertJSON(response, equals: ["status": "error", "message": "unknown-command", "command": "unknown-cmd"])
    }

    func testEmptyCommandReportsError() {
        let dispatcher = fixtureDispatcher()
        let response = dispatcher.process("   \n")
        assertJSON(response, equals: ["status": "error", "message": "empty-command"])
    }

    func testInvalidLogTargetPayloadReportsError() {
        let dispatcher = fixtureDispatcher()
        let response = dispatcher.process("log-target {\"unexpected\":42}")
        assertJSON(response, equals: ["status": "error", "message": "invalid-log-target-payload"])
    }

    func testStatsCommandInvokesProvider() {
        let expectation = expectation(description: "stats provider")
        let dispatcher = BoxAdminCommandDispatcher(
            statusProvider: { "" },
            logTargetUpdater: { _ in "" },
            reloadConfiguration: { _ in "" },
            statsProvider: {
                expectation.fulfill()
                return "{\"status\":\"ok\"}"
            }
        )

        let response = dispatcher.process("stats")
        XCTAssertEqual(response, "{\"status\":\"ok\"}")
        wait(for: [expectation], timeout: 0.1)
    }

    private func fixtureDispatcher() -> BoxAdminCommandDispatcher {
        BoxAdminCommandDispatcher(
            statusProvider: { "status" },
            logTargetUpdater: { _ in "log" },
            reloadConfiguration: { _ in "reload" },
            statsProvider: { "stats" }
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
