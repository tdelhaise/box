import XCTest
import NIOCore
@testable import BoxClient
@testable import BoxCore
@testable import BoxServer

final class BoxClientTests: XCTestCase {
    func testDetermineBindHostPrefersIPv6Wildcard() throws {
        let ipv6 = try SocketAddress(ipAddress: "2001:db8::1", port: 12345)
        XCTAssertEqual(BoxClient.determineBindHost(remoteAddress: ipv6), "::")
    }

    func testDetermineBindHostDefaultsToIPv4Wildcard() throws {
        let ipv4 = try SocketAddress(ipAddress: "192.0.2.10", port: 54321)
        XCTAssertEqual(BoxClient.determineBindHost(remoteAddress: ipv4), "0.0.0.0")
    }

    func testPingReturnsStatusMessage() async throws {
        let port = try allocateEphemeralUDPPort()
        let context = try await startServer(forcedPort: port, adminChannelEnabled: false)
        defer { context.tearDown() }

        try await context.waitForQueueInfrastructure()

        let options = BoxRuntimeOptions(
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
            clientAction: .ping,
            portMappingOrigin: .default,
            rootServers: []
        )

        let message = try await BoxClient.ping(with: options)
        XCTAssertTrue(message.hasPrefix("pong"))
        XCTAssertTrue(message.contains(BoxVersionInfo.version))
    }
}
