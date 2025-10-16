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
@main
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
    @Option(name: [.short, .long], help: "Target address (client) or bind address (server).")
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
        let cliLogLevel = Logger.Level(logLevelString: logLevel)
        let cliLogTarget = try resolveLogTarget()
        let resolvedMode: BoxRuntimeMode = server ? .server : .client
        let clientConfiguration = (resolvedMode == .client) ? try loadClientConfiguration() : nil

        let (effectiveLogLevel, logLevelOrigin): (Logger.Level, BoxRuntimeOptions.LogLevelOrigin) = {
            if logLevel != nil {
                return (cliLogLevel, .cliFlag)
            }
            if let configLevel = clientConfiguration?.logLevel {
                return (configLevel, .configuration)
            }
            return (.info, .default)
        }()

        let (effectiveLogTarget, logTargetOrigin): (BoxLogTarget, BoxRuntimeOptions.LogTargetOrigin) = {
            if let cliTarget = cliLogTarget {
                return (cliTarget, .cliFlag)
            }
            if let configTarget = clientConfiguration?.logTarget,
               let parsed = BoxLogTarget.parse(configTarget) {
                return (parsed, .configuration)
            }
            return (BoxRuntimeOptions.defaultLogTarget, .default)
        }()

        BoxLogging.bootstrap(level: effectiveLogLevel, target: effectiveLogTarget)

        let effectiveAddress: String = {
            if let cliAddress = address {
                return cliAddress
            }
            if resolvedMode == .client,
               let configAddress = clientConfiguration?.address,
               !configAddress.isEmpty {
                return configAddress
            }
            return resolvedMode == .server ? BoxRuntimeOptions.defaultServerBindAddress : BoxRuntimeOptions.defaultClientAddress
        }()

        let (effectivePort, portOrigin): (UInt16, BoxRuntimeOptions.PortOrigin) = {
            if let cliPort = port {
                return (cliPort, .cliFlag)
            }
            if resolvedMode == .client, let configPort = clientConfiguration?.port {
                return (configPort, .configuration)
            }
            return (BoxRuntimeOptions.defaultPort, .default)
        }()

        let runtimeOptions = BoxRuntimeOptions(
            mode: resolvedMode,
            address: effectiveAddress,
            port: effectivePort,
            portOrigin: portOrigin,
            configurationPath: configurationPath,
            adminChannelEnabled: adminChannel,
            logLevel: effectiveLogLevel,
            logTarget: effectiveLogTarget,
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

    /// Loads the client configuration from disk (if available).
    private func loadClientConfiguration() throws -> BoxClientConfiguration? {
        try BoxClientConfiguration.loadDefault(explicitPath: configurationPath)
    }

    /// Resolves the logging target based on CLI arguments.
    /// - Returns: Parsed target when provided.
    private func resolveLogTarget() throws -> BoxLogTarget? {
        guard let targetOption = logTarget else {
            return nil
        }
        guard let parsed = BoxLogTarget.parse(targetOption) else {
            throw ValidationError("Invalid --log-target. Expected stderr|stdout|file:<path>.")
        }
        return parsed
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
                subcommands: [Status.self, Ping.self, LogTarget.self, ReloadConfig.self, Stats.self]
            )
        }

        public init() {}

        /// `box admin status` — fetches the daemon status over the local socket.
        public struct Status: AsyncParsableCommand {
            @Option(name: .shortAndLong, help: "Admin socket path (defaults to ~/.box/run/boxd.socket).")
            public var socket: String?

            public init() {}

            public mutating func run() throws {
                let response = try Admin.sendCommand("status", socketOverride: socket)
                Admin.writeResponse(response)
            }
        }

        /// `box admin ping` — simple connectivity check.
        public struct Ping: AsyncParsableCommand {
            @Option(name: .shortAndLong, help: "Admin socket path (defaults to ~/.box/run/boxd.socket).")
            public var socket: String?

            public init() {}

            public mutating func run() throws {
                let response = try Admin.sendCommand("ping", socketOverride: socket)
                Admin.writeResponse(response)
            }
        }

        /// `box admin log-target <target>` — updates the runtime log destination.
        public struct LogTarget: AsyncParsableCommand {
            @Option(name: .shortAndLong, help: "Admin socket path (defaults to ~/.box/run/boxd.socket).")
            public var socket: String?

            @Argument(help: "Log target (stderr|stdout|file:<path>).")
            public var target: String

            public init() {}

            public mutating func run() throws {
                guard BoxLogTarget.parse(target) != nil else {
                    throw ValidationError("Invalid target. Expected stderr|stdout|file:<path>.")
                }
                let payload = try Admin.encodeJSON(["target": target])
                let response = try Admin.sendCommand("log-target \(payload)", socketOverride: socket)
                Admin.writeResponse(response)
            }
        }

        /// `box admin reload-config` — requests the daemon to reload its configuration file.
        public struct ReloadConfig: AsyncParsableCommand {
            /// Custom admin socket path override.
            @Option(name: .shortAndLong, help: "Admin socket path (defaults to ~/.box/run/boxd.socket).")
            public var socket: String?

            /// Explicit configuration file to reload.
            @Option(name: .shortAndLong, help: "Configuration PLIST path (defaults to the runtime path).")
            public var configuration: String?

            public init() {}

            public mutating func run() throws {
                let command: String
                if let configuration, !configuration.isEmpty {
                    let payload = try Admin.encodeJSON(["path": configuration])
                    command = "reload-config \(payload)"
                } else {
                    command = "reload-config"
                }
                let response = try Admin.sendCommand(command, socketOverride: socket)
                Admin.writeResponse(response)
            }
        }

        /// `box admin stats` — retrieves runtime statistics (log level, target, queue count, reload history).
        public struct Stats: AsyncParsableCommand {
            /// Custom admin socket path override.
            @Option(name: .shortAndLong, help: "Admin socket path (defaults to ~/.box/run/boxd.socket).")
            public var socket: String?

            public init() {}

            public mutating func run() throws {
                let response = try Admin.sendCommand("stats", socketOverride: socket)
                Admin.writeResponse(response)
            }
        }

        private static func sendCommand(_ command: String, socketOverride: String?) throws -> String {
            let socketPath = try resolveSocketPath(socketOverride)
            let transport = BoxAdminTransportFactory.makeTransport(socketPath: socketPath)
            do {
                return try transport.send(command: command)
            } catch let error as BoxAdminTransportError {
                throw ValidationError("Admin command failed: \(error.readableDescription)")
            } catch {
                throw ValidationError("Admin command failed: \(error.localizedDescription)")
            }
        }

        private static func resolveSocketPath(_ override: String?) throws -> String {
            if let override, !override.isEmpty {
                return NSString(string: override).expandingTildeInPath
            }
            guard let defaultPath = BoxPaths.adminSocketPath() else {
                throw ValidationError("Unable to determine admin socket path. Specify one with --socket.")
            }
            return defaultPath
        }

        /// Writes the received response to stdout and ensures the trailing newline is present.
        /// - Parameter response: Raw response string from the admin channel.
        private static func writeResponse(_ response: String) {
            FileHandle.standardOutput.write(response.data(using: .utf8) ?? Data())
            if !response.hasSuffix("\n") {
                FileHandle.standardOutput.write("\n".data(using: .utf8)!)
            }
        }

        /// Encodes a JSON payload used for admin commands (e.g. log-target, reload-config).
        /// - Parameter payload: Dictionary converted to JSON.
        /// - Returns: Sorted JSON string representation.
        private static func encodeJSON(_ payload: [String: String]) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            guard let json = String(data: data, encoding: .utf8) else {
                throw ValidationError("Unable to encode admin command payload.")
            }
            return json
        }
    }
}
