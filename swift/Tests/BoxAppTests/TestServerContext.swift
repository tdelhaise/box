import Foundation
import Dispatch
import Logging
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import BoxCore
@testable import BoxServer

/// Holds runtime information for a server instance spawned during tests.
struct ServerContext: Sendable {
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
    try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true, attributes: [FileAttributeKey.posixPermissions: 0o777])
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

/// Allocates an ephemeral UDP port bound to the loopback interface.
/// - Returns: The port number reserved for the caller.
/// - Throws: An `NSError` when socket operations fail.
func allocateEphemeralUDPPort() throws -> UInt16 {
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
