import XCTest
@testable import BoxServer
@testable import BoxCore
import Logging

final class BoxServerRuntimeControllerTests: XCTestCase {
    func testInitializationFromOptions() throws {
        let nodeId = UUID()
        let userId = UUID()
        let options = BoxRuntimeOptions(
            mode: .server,
            address: "127.0.0.1",
            port: 9001,
            portOrigin: .environment,
            addressOrigin: .cliFlag,
            configurationPath: "/tmp/config.plist",
            adminChannelEnabled: false,
            logLevel: .error,
            logTarget: .stdout,
            logLevelOrigin: .cliFlag,
            logTargetOrigin: .default,
            nodeId: nodeId,
            userId: userId,
            portMappingRequested: true,
            portMappingOrigin: .configuration,
            externalAddressOverride: "1.1.1.1",
            externalPortOverride: 10001,
            externalAddressOrigin: .cliFlag,
            rootServers: []
        )

        let controller = BoxServerRuntimeController(options: options)
        let state = controller.state.withLockedValue { $0 }

        XCTAssertEqual(state.configurationPath, "/tmp/config.plist")
        XCTAssertEqual(state.logLevel, .error)
        XCTAssertEqual(state.logLevelOrigin, .cliFlag)
        XCTAssertEqual(state.logTarget, .stdout)
        XCTAssertEqual(state.logTargetOrigin, .default)
        XCTAssertEqual(state.port, 9001)
        XCTAssertEqual(state.portOrigin, .environment)
        XCTAssertEqual(state.adminChannelEnabled, false)
        XCTAssertEqual(state.transport, nil) 
        XCTAssertEqual(state.nodeIdentifier, nodeId)
        XCTAssertEqual(state.userIdentifier, userId)
        XCTAssertEqual(state.portMappingRequested, true)
        XCTAssertEqual(state.portMappingOrigin, .configuration)
        XCTAssertEqual(state.manualExternalAddress, "1.1.1.1")
        XCTAssertEqual(state.manualExternalPort, 10001)
        XCTAssertEqual(state.manualExternalOrigin, .cliFlag)
    }
}
