import XCTest
import NIOCore
@testable import BoxClient

final class BoxClientTests: XCTestCase {
    func testDetermineBindHostPrefersIPv6Wildcard() throws {
        let ipv6 = try SocketAddress(ipAddress: "2001:db8::1", port: 12345)
        XCTAssertEqual(BoxClient.determineBindHost(remoteAddress: ipv6), "::")
    }

    func testDetermineBindHostDefaultsToIPv4Wildcard() throws {
        let ipv4 = try SocketAddress(ipAddress: "192.0.2.10", port: 54321)
        XCTAssertEqual(BoxClient.determineBindHost(remoteAddress: ipv4), "0.0.0.0")
    }
}
