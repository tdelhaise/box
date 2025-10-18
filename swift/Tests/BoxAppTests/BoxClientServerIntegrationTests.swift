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
            portMappingOrigin: .default
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
            portMappingOrigin: .default
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
            portMappingOrigin: .default
        )

        try await BoxClient.run(with: getOptions)

        let remaining = try await store.list(queue: "INBOX")
        XCTAssertTrue(remaining.isEmpty, "GET should consume the stored message")
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
        _ = try await store.ensureQueue("/uuid")

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
        try? await store.remove(queue: "/uuid", id: clientRecord.nodeUUID)
        try await store.put(storedObject, into: "/uuid")

        let clientOptions = BoxRuntimeOptions(
            mode: .client,
            address: "127.0.0.1",
            port: port,
            portOrigin: .cliFlag,
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
            portMappingOrigin: .default
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
            portMappingOrigin: .default
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

private func makeServerConfiguration(port: UInt16, adminEnabled: Bool) throws -> TestServerConfiguration {
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
            "port_mapping": false
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

private func allocateEphemeralUDPPort() throws -> UInt16 {
    let fd: Int32
    #if canImport(Darwin)
    fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
    #else
    fd = Glibc.socket(AF_INET, Int32(SOCK_DGRAM.rawValue), 0)
    #endif
    guard fd >= 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "unable to allocate socket"])
    }
    defer {
        #if canImport(Darwin)
        Darwin.close(fd)
        #else
        Glibc.close(fd)
        #endif
    }

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bindResult: Int32 = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
            #if canImport(Darwin)
            return Darwin.bind(fd, pointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            #else
            return Glibc.bind(fd, pointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            #endif
        }
    }
    guard bindResult == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "unable to bind test socket"])
    }

    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult: Int32 = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
            #if canImport(Darwin)
            return Darwin.getsockname(fd, pointer, &length)
            #else
            return Glibc.getsockname(fd, pointer, &length)
            #endif
        }
    }
    guard nameResult == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "unable to determine socket name"])
    }
    return UInt16(bigEndian: address.sin_port)
}
