import ArgumentParser
import BoxClient
import BoxCore
import BoxServer
import Foundation
import Logging

#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Swift Argument Parser entry point that validates CLI options before delegating to the runtime.
public struct BoxCommandParser: AsyncParsableCommand {
    /// Static configuration used by swift-argument-parser (command name and abstract description).
    public static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "box",
            abstract: "Box messaging toolkit (Swift rewrite).",
            subcommands: [Admin.self]
        )
    }

    /// Flag selecting server mode (`box --server`).
    @Flag(name: [.short, .long], help: "Run the Box daemon.")
    public var server: Bool = false

    /// Optional UDP port overriding the default (12567).
    @Option(name: [.short, .long], help: "UDP port (default \(BoxRuntimeOptions.defaultPort)).")
    public var port: UInt16?

    /// Optional remote address used when the client initiates a connection.
    @Option(name: [.short, .long], help: "Target address (client mode).")
    public var address: String?

    /// Optional configuration PLIST file.
    @Option(name: [.customLong("config")], help: "Path to the configuration PLIST.")
    public var configurationPath: String?

    /// Desired swift-log level parsed from the CLI.
    @Option(name: .long, help: "Log level (trace, debug, info, warn, error).")
    public var logLevel: String?

    /// Flag toggling the admin channel (server mode). `--no-admin-channel` disables it.
    @Flag(name: [.long], inversion: .prefixedNo, help: "Enable the local admin channel socket.")
    public var adminChannel: Bool = true

    /// Optional logging target override (`stderr|stdout|file:/path`).
    @Option(name: .long, help: "Log target (stderr|stdout|file:<path>).")
    public var logTarget: String?

    /// Optional PUT action described as `<queue>[:content-type]`.
    @Option(name: .customLong("put"), help: "PUT queue path (format: /queue[:content-type]).")
    public var putDescriptor: String?

    /// Optional GET queue path.
    @Option(name: .customLong("get"), help: "GET queue path.")
    public var getQueue: String?

    /// Optional inline payload used for PUT.
    @Option(name: .customLong("data"), help: "Inline data used with --put (UTF-8).")
    public var dataString: String?

    /// Default memberwise initializer required by swift-argument-parser.
    public init() {}

    /// Parses CLI arguments, configures logging, and dispatches to either the server or the client.
    public mutating func run() async throws {
        let selectedLogLevel = Logger.Level(logLevelString: logLevel)
        let (resolvedLogTarget, logTargetOrigin) = try resolveLogTarget()
        BoxLogging.bootstrap(level: selectedLogLevel, target: resolvedLogTarget)

        let resolvedMode: BoxRuntimeMode = server ? .server : .client
        let resolvedAddress = address ?? BoxRuntimeOptions.defaultAddress
        let (resolvedPort, portOrigin): (UInt16, BoxRuntimeOptions.PortOrigin) = {
            if let cliPort = port {
                return (cliPort, .cliFlag)
            }
            return (BoxRuntimeOptions.defaultPort, .default)
        }()
        let logLevelOrigin: BoxRuntimeOptions.LogLevelOrigin = (logLevel != nil) ? .cliFlag : .default

        let runtimeOptions = BoxRuntimeOptions(
            mode: resolvedMode,
            address: resolvedAddress,
            port: resolvedPort,
            portOrigin: portOrigin,
            configurationPath: configurationPath,
            adminChannelEnabled: adminChannel,
            logLevel: selectedLogLevel,
            logTarget: resolvedLogTarget,
            logLevelOrigin: logLevelOrigin,
            logTargetOrigin: logTargetOrigin,
            clientAction: try resolveClientAction(for: resolvedMode)
        )

        switch resolvedMode {
        case .server:
            try await BoxServer.run(with: runtimeOptions)
        case .client:
            try await BoxClient.run(with: runtimeOptions)
        }
    }

    /// Converts CLI flags into a concrete client action.
    /// - Parameter mode: Current runtime mode.
    /// - Returns: Client action, defaults to `.handshake`.
    /// - Throws: `ValidationError` when conflicting options are supplied.
    private func resolveClientAction(for mode: BoxRuntimeMode) throws -> BoxClientAction {
        guard mode == .client else {
            return .handshake
        }

        if let descriptor = putDescriptor {
            guard getQueue == nil else {
                throw ValidationError("Cannot combine --put and --get in the same invocation.")
            }
            guard let dataString else {
                throw ValidationError("--put requires --data <payload>.")
            }
            let components = descriptor.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let queuePath = String(components[0])
            guard queuePath.hasPrefix("/") else {
                throw ValidationError("--put queue path must start with '/'.")
            }
            let contentType = components.count == 2 ? String(components[1]) : "application/octet-stream"
            return .put(queuePath: queuePath, contentType: contentType, data: Array(dataString.utf8))
        }

        if let queuePath = getQueue {
            guard queuePath.hasPrefix("/") else {
                throw ValidationError("--get queue path must start with '/'.")
            }
            return .get(queuePath: queuePath)
        }

        return .handshake
    }

    /// Resolves the logging target based on CLI arguments.
    /// - Returns: Tuple containing the parsed target and its origin.
    private func resolveLogTarget() throws -> (BoxLogTarget, BoxRuntimeOptions.LogTargetOrigin) {
        guard let targetOption = logTarget else {
            return (BoxRuntimeOptions.defaultLogTarget, .default)
        }
        guard let parsed = BoxLogTarget.parse(targetOption) else {
            throw ValidationError("Invalid --log-target. Expected stderr|stdout|file:<path>.")
        }
        return (parsed, .cliFlag)
    }
}

// MARK: - Admin Subcommands

extension BoxCommandParser {
    /// `box admin` namespace handling administrative commands.
    public struct Admin: AsyncParsableCommand {
        public static var configuration: CommandConfiguration {
            CommandConfiguration(
                commandName: "admin",
                abstract: "Interact with the local admin channel.",
                subcommands: [Status.self]
            )
        }

        public init() {}

        /// `box admin status` — fetches the daemon status over the local socket.
        public struct Status: AsyncParsableCommand {
            @Option(name: .shortAndLong, help: "Admin socket path (defaults to ~/.box/run/boxd.socket).")
            public var socket: String?

            public init() {}

            public mutating func run() throws {
                guard let path = resolveSocketPath() else {
                    throw ValidationError("Unable to determine admin socket path. Specify one with --socket.")
                }
                let response = try queryStatus(socketPath: path)
                FileHandle.standardOutput.write(response.data(using: .utf8) ?? Data())
                if !response.hasSuffix("\n") {
                    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
                }
            }

            /// Determines the socket path to use, applying defaulting rules.
            /// - Returns: Expanded socket path or `nil` when it cannot be determined.
            private func resolveSocketPath() -> String? {
                if let socket, !socket.isEmpty {
                    return NSString(string: socket).expandingTildeInPath
                }
                return BoxPaths.adminSocketPath()
            }

            /// Sends the `status` command to the admin channel and returns the raw response.
            /// - Parameter socketPath: Filesystem path to the admin socket.
            /// - Returns: Response string from the daemon.
            /// - Throws: `ValidationError` when the socket cannot be contacted or the payload cannot be read.
            private func queryStatus(socketPath: String) throws -> String {
                #if os(Linux)
                let fileDescriptor = Glibc.socket(AF_UNIX, Int32(SOCK_STREAM), 0)
                #else
                let fileDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
                #endif
                guard fileDescriptor >= 0 else {
                    throw ValidationError("Failed to create admin socket.")
                }
                defer {
                    #if os(Linux)
                    _ = Glibc.close(fileDescriptor)
                    #else
                    _ = Darwin.close(fileDescriptor)
                    #endif
                }

                var address = sockaddr_un()
                address.sun_family = sa_family_t(AF_UNIX)
                var pathBytes = Array(socketPath.utf8)
                let maxLength = MemoryLayout.size(ofValue: address.sun_path) - 1
                if pathBytes.count > maxLength {
                    pathBytes = Array(pathBytes.prefix(maxLength))
                }
                withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                    buffer.initializeMemory(as: UInt8.self, repeating: 0)
                    pathBytes.withUnsafeBytes { source in
                        if let dest = buffer.baseAddress, let src = source.baseAddress {
                            memcpy(dest, src, pathBytes.count)
                        }
                    }
                }
                let sockLen = socklen_t(MemoryLayout.size(ofValue: address) - MemoryLayout.size(ofValue: address.sun_path) + pathBytes.count + 1)
                let connectResult = withUnsafePointer(to: &address) { pointer -> Int32 in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                        #if os(Linux)
                        return Glibc.connect(fileDescriptor, sockaddrPointer, sockLen)
                        #else
                        return Darwin.connect(fileDescriptor, sockaddrPointer, sockLen)
                        #endif
                    }
                }
                guard connectResult == 0 else {
                    throw ValidationError("Unable to connect to admin socket at \(socketPath)")
                }

                let request = "status\n"
                try request.withCString { pointer in
                    let length = strlen(pointer)
                    var totalWritten: size_t = 0
                    while totalWritten < length {
                        #if os(Linux)
                        let written = Glibc.write(fileDescriptor, pointer + totalWritten, length - totalWritten)
                        #else
                        let written = Darwin.write(fileDescriptor, pointer + totalWritten, length - totalWritten)
                        #endif
                        if written <= 0 {
                            throw ValidationError("Failed to write request to admin socket.")
                        }
                        totalWritten += size_t(written)
                    }
                }

                var buffer = [UInt8](repeating: 0, count: 4096)
                var response = Data()
                while true {
                    #if os(Linux)
                    let bytesRead = Glibc.read(fileDescriptor, &buffer, buffer.count)
                    #else
                    let bytesRead = Darwin.read(fileDescriptor, &buffer, buffer.count)
                    #endif
                    if bytesRead < 0 {
                        throw ValidationError("Failed to read response from admin socket.")
                    }
                    if bytesRead == 0 {
                        break
                    }
                    response.append(buffer, count: Int(bytesRead))
                }

                guard let responseString = String(data: response, encoding: .utf8) else {
                    throw ValidationError("Admin response was not valid UTF-8.")
                }
                return responseString
            }
        }
    }
}
