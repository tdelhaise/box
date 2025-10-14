import ArgumentParser
import BoxClient
import BoxCore
import BoxServer
import Logging

/// Swift Argument Parser entry point that validates CLI options before delegating to the runtime.
public struct BoxCommandParser: AsyncParsableCommand {
    /// Static configuration used by swift-argument-parser (command name and abstract description).
    public static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "box",
            abstract: "Box messaging toolkit (Swift rewrite)."
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
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardError(label: label)
            handler.logLevel = selectedLogLevel
            return handler
        }

        let resolvedMode: BoxRuntimeMode = server ? .server : .client
        let runtimeOptions = BoxRuntimeOptions(
            mode: resolvedMode,
            address: address ?? BoxRuntimeOptions.defaultAddress,
            port: port ?? BoxRuntimeOptions.defaultPort,
            configurationPath: configurationPath,
            adminChannelEnabled: adminChannel,
            logLevel: selectedLogLevel,
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
}
