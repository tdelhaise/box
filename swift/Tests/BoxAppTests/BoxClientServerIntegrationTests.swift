import XCTest
import Foundation
import Logging
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import BoxClient
@testable import BoxCore
@testable import BoxServer

final class BoxClientServerIntegrationTests: XCTestCase {
    func testHandshakeEndToEnd() async throws {
        let port = try allocateEphemeralUDPPort()
        let serverConfiguration = try makeServerConfiguration(port: port, adminEnabled: false)
        let context = try await startServer(
            configurationData: serverConfiguration.data,
            forcedPort: port,
            adminChannelEnabled: false
        )
        defer { context.tearDown() }

        try await context.waitForQueueInfrastructure()

        let configuration = try BoxConfiguration.load(from: context.configurationURL).configuration
        XCTAssertEqual(configuration.common.nodeUUID, serverConfiguration.nodeId)
        XCTAssertEqual(configuration.common.userUUID, serverConfiguration.userId)
        XCTAssertEqual(configuration.server.port, port)

        let clientOptions = BoxRuntimeOptions(
            mode: .client,
            address: "127.0.0.1",
            port: port,
            portOrigin: .cliFlag,
            addressOrigin: .cliFlag,
            configurationPath: context.configurationURL.path,
            adminChannelEnabled: false,
            logLevel: .info,
            logTarget: .stderr,
            logLevelOrigin: .default,
            logTargetOrigin: .default,
            nodeId: serverConfiguration.nodeId,
            userId: serverConfiguration.userId,
            portMappingRequested: false,
            clientAction: .handshake,
            portMappingOrigin: .default,
            rootServers: []
        )

        try await BoxClient.run(with: clientOptions)

        let queuesRoot = context.homeDirectory.appendingPathComponent(".box/queues", isDirectory: true)
        let store = try await BoxServerStore(root: queuesRoot, logger: Logger(label: "box.tests.store.handshake"))
        let entries = try await store.list(queue: "INBOX")
        XCTAssertTrue(entries.isEmpty, "Handshake should not enqueue any object")
    }

    func testPutAndGetRoundTrip() async throws {
        let port = try allocateEphemeralUDPPort()
        let serverConfiguration = try makeServerConfiguration(port: port, adminEnabled: false)
        let context = try await startServer(
            configurationData: serverConfiguration.data,
            forcedPort: port,
            adminChannelEnabled: false
        )
        defer { context.tearDown() }

        try await context.waitForQueueInfrastructure()

        let payload = Array("Hello, Box!".utf8)
        let putOptions = BoxRuntimeOptions(
            mode: .client,
            address: "127.0.0.1",
            port: port,
            portOrigin: .cliFlag,
            addressOrigin: .cliFlag,
            configurationPath: context.configurationURL.path,
            adminChannelEnabled: false,
            logLevel: .info,
            logTarget: .stderr,
            logLevelOrigin: .default,
            logTargetOrigin: .default,
            nodeId: serverConfiguration.nodeId,
            userId: serverConfiguration.userId,
            portMappingRequested: false,
            clientAction: .put(queuePath: "INBOX", contentType: "text/plain", data: payload),
            portMappingOrigin: .default,
            rootServers: []
        )

        try await BoxClient.run(with: putOptions)

        let queuesRoot = context.homeDirectory.appendingPathComponent(".box/queues", isDirectory: true)
        let storeLogger = Logger(label: "box.tests.store.putget")
        let store = try await BoxServerStore(root: queuesRoot, logger: storeLogger)
        let storedMessages = try await store.list(queue: "INBOX")
        XCTAssertEqual(storedMessages.count, 1, "PUT should persist a single message")
        guard let reference = storedMessages.first else {
            XCTFail("Missing stored message reference")
            return
        }
        let storedObject = try await store.read(reference: reference)
        XCTAssertEqual(storedObject.data, payload)
        XCTAssertEqual(storedObject.contentType, "text/plain")
        XCTAssertEqual(storedObject.nodeId, serverConfiguration.nodeId)
        XCTAssertEqual(storedObject.userId, serverConfiguration.userId)

        let getOptions = BoxRuntimeOptions(
            mode: .client,
            address: "127.0.0.1",
            port: port,
            portOrigin: .cliFlag,
            addressOrigin: .cliFlag,
            configurationPath: context.configurationURL.path,
            adminChannelEnabled: false,
            logLevel: .info,
            logTarget: .stderr,
            logLevelOrigin: .default,
            logTargetOrigin: .default,
            nodeId: serverConfiguration.nodeId,
            userId: serverConfiguration.userId,
            portMappingRequested: false,
            clientAction: .get(queuePath: "INBOX"),
            portMappingOrigin: .default,
            rootServers: []
        )

        try await BoxClient.run(with: getOptions)

        let remaining = try await store.list(queue: "INBOX")
        XCTAssertTrue(remaining.isEmpty, "GET should consume the stored message")
    }

    func testGetDoesNotConsumeOnPermanentQueue() async throws {
        let port = try allocateEphemeralUDPPort()
        let serverConfiguration = try makeServerConfiguration(port: port, adminEnabled: false, permanentQueues: ["INBOX"])
        let context = try await startServer(
            configurationData: serverConfiguration.data,
            forcedPort: port,
            adminChannelEnabled: false
        )
        defer { context.tearDown() }

        try await context.waitForQueueInfrastructure()

        let payload = Array("Persistent payload".utf8)
        let putOptions = BoxRuntimeOptions(
            mode: .client,
            address: "127.0.0.1",
            port: port,
            portOrigin: .cliFlag,
            addressOrigin: .cliFlag,
            configurationPath: context.configurationURL.path,
            adminChannelEnabled: false,
            logLevel: .info,
            logTarget: .stderr,
            logLevelOrigin: .default,
            logTargetOrigin: .default,
            nodeId: serverConfiguration.nodeId,
            userId: serverConfiguration.userId,
            portMappingRequested: false,
            clientAction: .put(queuePath: "INBOX", contentType: "text/plain", data: payload),
            portMappingOrigin: .default,
            rootServers: []
        )

        try await BoxClient.run(with: putOptions)

        let queuesRoot = context.homeDirectory.appendingPathComponent(".box/queues", isDirectory: true)
        let store = try await BoxServerStore(root: queuesRoot, logger: Logger(label: "box.tests.store.permanent"))
        let storedMessages = try await store.list(queue: "INBOX")
        XCTAssertEqual(storedMessages.count, 1)

        let getOptions = BoxRuntimeOptions(
            mode: .client,
            address: "127.0.0.1",
            port: port,
            portOrigin: .cliFlag,
            addressOrigin: .cliFlag,
            configurationPath: context.configurationURL.path,
            adminChannelEnabled: false,
            logLevel: .info,
            logTarget: .stderr,
            logLevelOrigin: .default,
            logTargetOrigin: .default,
            nodeId: serverConfiguration.nodeId,
            userId: serverConfiguration.userId,
            portMappingRequested: false,
            clientAction: .get(queuePath: "INBOX"),
            portMappingOrigin: .default,
            rootServers: []
        )

        try await BoxClient.run(with: getOptions)

        let afterFirstRead = try await store.list(queue: "INBOX")
        XCTAssertEqual(afterFirstRead.count, 1, "Permanent queue should retain messages after GET")

        try await BoxClient.run(with: getOptions)

        let afterSecondRead = try await store.list(queue: "INBOX")
        XCTAssertEqual(afterSecondRead.count, 1, "Permanent queue should continue to retain messages after repeated GET operations")
    }

    func testLocateRequestSucceedsForKnownClient() async throws {
        let port = try allocateEphemeralUDPPort()
        let serverConfiguration = try makeServerConfiguration(port: port, adminEnabled: false)
        let context = try await startServer(
            configurationData: serverConfiguration.data,
            forcedPort: port,
            adminChannelEnabled: false
        )
        defer { context.tearDown() }

        try await context.waitForQueueInfrastructure()

        let queuesRoot = context.homeDirectory.appendingPathComponent(".box/queues", isDirectory: true)
        let store = try await BoxServerStore(root: queuesRoot, logger: Logger(label: "box.tests.store.locate"))
        _ = try await store.ensureQueue("/whoswho")

        let clientNodeID = UUID()
        let clientUserID = UUID()
        let clientRecord = LocationServiceNodeRecord.make(
            userUUID: clientUserID,
            nodeUUID: clientNodeID,
            port: port,
            probedGlobalIPv6: [],
            ipv6Error: nil,
            portMappingEnabled: false,
            portMappingOrigin: .default
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let recordData = try encoder.encode(clientRecord)
        let storedObject = BoxStoredObject(
            id: clientRecord.nodeUUID,
            contentType: "application/json; charset=utf-8",
            data: [UInt8](recordData),
            nodeId: clientRecord.nodeUUID,
            userId: clientRecord.userUUID,
            userMetadata: ["schema": "box.location-service.v1"]
        )
        try? await store.remove(queue: "/whoswho", id: clientRecord.nodeUUID)
        try await store.put(storedObject, into: "/whoswho")

        let clientOptions = BoxRuntimeOptions(
            mode: .client,
            address: "127.0.0.1",
            port: port,
            portOrigin: .cliFlag,
            addressOrigin: .cliFlag,
            configurationPath: context.configurationURL.path,
            adminChannelEnabled: false,
            logLevel: .info,
            logTarget: .stderr,
            logLevelOrigin: .default,
            logTargetOrigin: .default,
            nodeId: clientNodeID,
            userId: clientUserID,
            portMappingRequested: false,
            clientAction: .locate(node: serverConfiguration.nodeId),
            portMappingOrigin: .default,
            rootServers: []
        )

        try await BoxClient.run(with: clientOptions)
    }

    func testLocateRequestFailsForUnknownClient() async throws {
        let port = try allocateEphemeralUDPPort()
        let serverConfiguration = try makeServerConfiguration(port: port, adminEnabled: false)
        let context = try await startServer(
            configurationData: serverConfiguration.data,
            forcedPort: port,
            adminChannelEnabled: false
        )
        defer { context.tearDown() }

        try await context.waitForQueueInfrastructure()

        let clientOptions = BoxRuntimeOptions(
            mode: .client,
            address: "127.0.0.1",
            port: port,
            portOrigin: .cliFlag,
            addressOrigin: .cliFlag,
            configurationPath: context.configurationURL.path,
            adminChannelEnabled: false,
            logLevel: .info,
            logTarget: .stderr,
            logLevelOrigin: .default,
            logTargetOrigin: .default,
            nodeId: UUID(),
            userId: UUID(),
            portMappingRequested: false,
            clientAction: .locate(node: serverConfiguration.nodeId),
            portMappingOrigin: .default,
            rootServers: []
        )

        do {
            try await BoxClient.run(with: clientOptions)
            XCTFail("expected locate to fail")
        } catch {
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "BoxClientLocate")
            XCTAssertEqual(nsError.code, Int(BoxCodec.Status.unauthorized.rawValue))
        }
    }
}

// MARK: - Helpers

private struct TestServerConfiguration {
    let data: Data
    let nodeId: UUID
    let userId: UUID
}

private func makeServerConfiguration(port: UInt16, adminEnabled: Bool, permanentQueues: [String] = []) throws -> TestServerConfiguration {
    let node = UUID()
    let user = UUID()
    let plist: [String: Any] = [
        "common": [
            "node_uuid": node.uuidString,
            "user_uuid": user.uuidString
        ],
        "server": [
            "port": port,
            "log_level": "info",
            "log_target": "stderr",
            "admin_channel": adminEnabled,
            "port_mapping": false,
            "permanent_queues": permanentQueues
        ],
        "client": [
            "address": "127.0.0.1",
            "port": port,
            "log_level": "info",
            "log_target": "stderr"
        ]
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    return TestServerConfiguration(data: data, nodeId: node, userId: user)
}
