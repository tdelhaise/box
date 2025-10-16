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
        let queueCount = (statusJSON["queueCount"] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThanOrEqual(queueCount, 1)
        XCTAssertEqual(statusJSON["queueRoot"] as? String, context.homeDirectory.appendingPathComponent(".box/queues").path)
        XCTAssertNotNil(statusJSON["queueFreeBytes"] as? NSNumber)
    }

    func testReloadConfigUpdatesLogLevel() async throws {
        let config = try PropertyListSerialization.data(
            fromPropertyList: [
                "log_level": "info",
                "admin_channel": true
            ],
            format: .xml,
            options: 0
        )

        let context = try await startServer(configurationData: config)
        defer { context.tearDown() }

        try await context.waitForAdminSocket()
        let transport = BoxAdminTransportFactory.makeTransport(socketPath: context.socketPath)

        let updatedConfig = try PropertyListSerialization.data(
            fromPropertyList: [
                "log_level": "debug",
                "admin_channel": true
            ],
            format: .xml,
            options: 0
        )
        try updatedConfig.write(to: context.configurationURL)

        let reloadResponse = try transport.send(command: "reload-config {\"path\":\"\(context.configurationURL.path)\"}")
        let reloadJSON = try decodeJSON(reloadResponse)
        XCTAssertEqual(reloadJSON["status"] as? String, "ok")
        XCTAssertEqual(reloadJSON["logLevel"] as? String, "debug")
        XCTAssertEqual(reloadJSON["logLevelOrigin"] as? String, "configuration")
        let reloadedNodeUUID = reloadJSON["nodeUUID"] as? String
        XCTAssertNotNil(reloadedNodeUUID)

        let statsResponse = try transport.send(command: "stats")
        let statsJSON = try decodeJSON(statsResponse)
        XCTAssertEqual(statsJSON["logLevel"] as? String, "debug")
        XCTAssertEqual(statsJSON["logLevelOrigin"] as? String, "configuration")
        let statsQueueCount = (statsJSON["queueCount"] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThanOrEqual(statsQueueCount, 1)
        XCTAssertNotNil(statsJSON["queueFreeBytes"] as? NSNumber)

        let verificationLogger = Logger(label: "box.integration.reload")
        XCTAssertEqual(verificationLogger.logLevel, .debug)

        let statusAfter = try decodeJSON(try transport.send(command: "status"))
        let statusNodeUUID = statusAfter["nodeUUID"] as? String
        XCTAssertEqual(statusAfter["logLevel"] as? String, "debug")
        XCTAssertEqual(statusNodeUUID, reloadedNodeUUID)
        XCTAssertNotNil(statusNodeUUID.flatMap(UUID.init(uuidString:)))
        let statusAfterQueueCount = (statusAfter["queueCount"] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThanOrEqual(statusAfterQueueCount, 1)
        XCTAssertEqual(statusAfter["queueRoot"] as? String, context.homeDirectory.appendingPathComponent(".box/queues").path)
        XCTAssertNotNil(statusAfter["queueFreeBytes"] as? NSNumber)
    }
}

// MARK: - Helpers

private struct ServerContext {
    let homeDirectory: URL
    let socketPath: String
    let configurationURL: URL
    let originalHome: String?
    let serverTask: Task<Void, Error>

    func waitForAdminSocket(timeout: TimeInterval = 10.0) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error?
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: socketPath) {
                return
            }
            do {
                let probeTransport = BoxAdminTransportFactory.makeTransport(socketPath: socketPath)
                _ = try probeTransport.send(command: "ping")
                return
            } catch {
                lastError = error
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if let error = lastError {
            throw error
        }
        throw NSError(domain: "BoxAdminIntegrationTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "admin socket not created in time"])
    }

    func tearDown() {
        serverTask.cancel()
        waitForTaskCancellation(serverTask)
        if let originalHome {
            setenv("HOME", originalHome, 1)
        } else {
            unsetenv("HOME")
        }
        try? FileManager.default.removeItem(at: homeDirectory)
        BoxLogging.update(target: .stderr)
        BoxLogging.update(level: .info)
    }
}

private func startServer(configurationData: Data? = nil) async throws -> ServerContext {
    let tempRoot = URL(fileURLWithPath: "/tmp", isDirectory: true)
    let tempHome = tempRoot.appendingPathComponent("box-tests-\(UUID().uuidString)", isDirectory: true)
    let boxDirectory = tempHome.appendingPathComponent(".box", isDirectory: true)
    let runDirectory = boxDirectory.appendingPathComponent("run", isDirectory: true)
    try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)

    let configurationURL = boxDirectory.appendingPathComponent("boxd.plist")
    if let configurationData {
        try configurationData.write(to: configurationURL)
    }

    let originalHome = getenv("HOME").map { String(cString: $0) }
    setenv("HOME", tempHome.path, 1)

    BoxLogging.bootstrap(level: .info, target: .stderr)
    BoxLogging.update(level: .info)
    BoxLogging.update(target: .stderr)

    let options = BoxRuntimeOptions(
        mode: .server,
        address: "127.0.0.1",
        port: 0,
        portOrigin: .default,
        configurationPath: configurationData == nil ? nil : configurationURL.path,
        adminChannelEnabled: true,
        logLevel: .info,
        logTarget: .stderr,
        logLevelOrigin: .default,
        logTargetOrigin: .default
    )

    let task = Task {
        try await BoxServer.run(with: options)
    }

    let socketPath = runDirectory.appendingPathComponent("boxd.socket").path
    return ServerContext(
        homeDirectory: tempHome,
        socketPath: socketPath,
        configurationURL: configurationURL,
        originalHome: originalHome,
        serverTask: task
    )
}

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

private func waitForTaskCancellation(_ task: Task<Void, Error>, timeout: TimeInterval = 5.0) {
    let group = DispatchGroup()
    group.enter()
    Task.detached {
        defer { group.leave() }
        _ = try? await task.value
    }
    _ = group.wait(timeout: .now() + timeout)
}
