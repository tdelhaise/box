import Foundation
import Dispatch
import Logging
@testable import BoxCore
@testable import BoxServer

/// Holds runtime information for a server instance spawned during tests.
struct ServerContext {
    /// Temporary home directory assigned to the server process.
    let homeDirectory: URL
    /// Path to the admin transport socket (or named pipe).
    let socketPath: String
    /// Location of the configuration PLIST backing this test instance.
    let configurationURL: URL
    /// UDP port requested at launch (0 when using an ephemeral port).
    let port: UInt16
    /// Indicates whether the admin channel was enabled for this instance.
    let adminChannelEnabled: Bool
    /// Original `HOME` environment variable value before the server was launched.
    let originalHome: String?
    /// Task executing `BoxServer.run`.
    let serverTask: Task<Void, Error>

    /// Waits for the admin socket (or equivalent transport) to become reachable.
    /// - Parameter timeout: Maximum amount of time to wait for the transport to appear.
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
        throw NSError(domain: "BoxTestHelpers", code: 1, userInfo: [NSLocalizedDescriptionKey: "admin socket not created in time"])
    }

    /// Waits for the default queue infrastructure to be created by the server.
    /// - Parameters:
    ///   - queueName: Queue that must exist (defaults to `INBOX`).
    ///   - timeout: Maximum amount of time to wait.
    func waitForQueueInfrastructure(queueName: String = "INBOX", timeout: TimeInterval = 10.0) async throws {
        let queueRoot = homeDirectory.appendingPathComponent(".box/queues", isDirectory: true)
        let queuePath = queueRoot.appendingPathComponent(queueName, isDirectory: true)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: queuePath.path) {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw NSError(domain: "BoxTestHelpers", code: 2, userInfo: [NSLocalizedDescriptionKey: "queue infrastructure not created in time"])
    }

    /// Terminates the server task and restores the test environment.
    func tearDown() {
        serverTask.cancel()
        waitForTaskCancellation(serverTask)
        if let originalHome {
            setenv("HOME", originalHome, 1)
        } else {
            unsetenv("HOME")
        }
        unsetenv("BOX_SKIP_NAT_PROBE")
        try? FileManager.default.removeItem(at: homeDirectory)
        BoxLogging.update(target: .stderr)
        BoxLogging.update(level: .info)
    }
}

/// Boots a test server instance using a temporary environment.
/// - Parameter configurationData: Optional raw PLIST data used to seed `Box.plist`.
/// - Returns: A context object describing the spawned server instance.
func startServer(configurationData: Data? = nil, forcedPort: UInt16? = nil, adminChannelEnabled: Bool = true) async throws -> ServerContext {
    let tempRoot = URL(fileURLWithPath: "tmp", isDirectory: true)
    try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    let tempHome = tempRoot.appendingPathComponent("box-tests-\(UUID().uuidString)", isDirectory: true)
    let originalHome = getenv("HOME").map { String(cString: $0) }
    setenv("HOME", tempHome.path, 1)
    setenv("BOX_SKIP_NAT_PROBE", "1", 1)

    let boxDirectory = tempHome.appendingPathComponent(".box", isDirectory: true)
    let runDirectory = boxDirectory.appendingPathComponent("run", isDirectory: true)
    try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)

    let configurationURL = boxDirectory.appendingPathComponent("Box.plist")
    if let configurationData {
        try configurationData.write(to: configurationURL)
    }
    let configurationResult = try BoxConfiguration.load(from: configurationURL)
    let configuration = configurationResult.configuration

    BoxLogging.bootstrap(level: .info, target: .stderr)
    BoxLogging.update(level: .info)
    BoxLogging.update(target: .stderr)

    let requestedPort = forcedPort ?? 0

    let options = BoxRuntimeOptions(
        mode: .server,
        address: "127.0.0.1",
        port: requestedPort,
        portOrigin: .cliFlag,
        configurationPath: configurationURL.path,
        adminChannelEnabled: adminChannelEnabled,
        logLevel: .info,
        logTarget: .stderr,
        logLevelOrigin: .default,
        logTargetOrigin: .default,
        nodeId: configuration.common.nodeUUID,
        userId: configuration.common.userUUID,
        portMappingRequested: false,
        clientAction: .handshake,
        portMappingOrigin: .default
    )

    let task = Task {
        try await BoxServer.run(with: options)
    }

    let socketPath = runDirectory.appendingPathComponent("boxd.socket").path
    return ServerContext(
        homeDirectory: tempHome,
        socketPath: socketPath,
        configurationURL: configurationURL,
        port: requestedPort,
        adminChannelEnabled: adminChannelEnabled,
        originalHome: originalHome,
        serverTask: task
    )
}

/// Waits for a task to finish after issuing a cancellation request.
/// - Parameters:
///   - task: Task to monitor.
///   - timeout: Maximum number of seconds to wait.
func waitForTaskCancellation(_ task: Task<Void, Error>, timeout: TimeInterval = 5.0) {
    let group = DispatchGroup()
    group.enter()
    Task.detached {
        defer { group.leave() }
        _ = try? await task.value
    }
    _ = group.wait(timeout: .now() + timeout)
}
