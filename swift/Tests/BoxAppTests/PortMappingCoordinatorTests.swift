import XCTest
import Logging
@testable import BoxServer
@testable import BoxCore

final class PortMappingCoordinatorTests: XCTestCase {
    func testProbeReportSerialization() throws {
        let report = PortMappingCoordinator.ProbeReport(
            backend: "test-backend",
            status: "ok",
            externalPort: 12345,
            externalIPv4: "1.2.3.4",
            lifetime: 3600,
            gateway: "192.168.1.1",
            service: "test-service",
            error: nil,
            peerStatus: "ok",
            peerLifetime: 7200,
            peerLastUpdate: Date(timeIntervalSince1970: 1000),
            peerError: nil
        )

        let dict = report.toDictionary()
        XCTAssertEqual(dict["backend"] as? String, "test-backend")
        XCTAssertEqual(dict["status"] as? String, "ok")
        XCTAssertEqual(dict["externalPort"] as? Int, 12345)
        XCTAssertEqual(dict["externalIPv4"] as? String, "1.2.3.4")
        XCTAssertEqual(dict["leaseSeconds"] as? UInt32, 3600)
        XCTAssertEqual(dict["gateway"] as? String, "192.168.1.1")
        XCTAssertEqual(dict["service"] as? String, "test-service")
        XCTAssertNil(dict["error"])
        XCTAssertNil(dict["errorCode"])
        XCTAssertEqual(dict["peerStatus"] as? String, "ok")
        XCTAssertEqual(dict["peerLifetime"] as? UInt32, 7200)
        XCTAssertNotNil(dict["peerLastUpdated"])
        XCTAssertNil(dict["peerError"])
    }

    #if !os(Windows)
    func testCoordinatorProbeSkipsWhenEnvVarIsSet() async throws {
        setenv("BOX_SKIP_NAT_PROBE", "1", 1)
        defer { unsetenv("BOX_SKIP_NAT_PROBE") }

        let logger = Logger(label: "test")
        let coordinator = PortMappingCoordinator(
            logger: logger,
            port: 1234,
            origin: .cliFlag,
            nodeIdentifier: UUID(),
            userIdentifier: UUID()
        ) { _ in }

        let reports = await coordinator.probe(gatewayOverride: nil)
        XCTAssertTrue(reports.isEmpty, "Probe should return no reports when skipped via environment variable")
    }
    #endif
}
