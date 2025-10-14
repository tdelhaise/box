import Foundation
import Logging

/// Identifies whether the runtime should launch the server or the client.
public enum BoxRuntimeMode: Sendable {
    /// Launch the UDP server daemon (`box --server`).
    case server
    /// Launch the UDP client (default mode).
    case client
}

/// Represents the high-level action the client should execute after the handshake.
public enum BoxClientAction: Sendable {
    /// Perform only the HELLO/STATUS handshake and exit.
    case handshake
    /// Send a PUT request with the given queue path, content type, and payload bytes.
    case put(queuePath: String, contentType: String, data: [UInt8])
    /// Send a GET request for the supplied queue path.
    case get(queuePath: String)
}

/// Aggregates runtime options shared between the client and the server entry points.
public struct BoxRuntimeOptions: Sendable {
    /// Indicates how the effective port value was obtained.
    public enum PortOrigin: Sendable {
        /// Default port (no override provided).
        case `default`
        /// CLI `--port` flag.
        case cliFlag
        /// Environment variable (e.g. `BOXD_PORT`).
        case environment
        /// Configuration file override.
        case configuration
        /// Positional argument (client legacy).
        case positional
    }

    /// Indicates how the effective log level was determined.
    public enum LogLevelOrigin: Sendable {
        /// Default `.info` level.
        case `default`
        /// CLI `--log-level` flag.
        case cliFlag
        /// Configuration file override.
        case configuration
    }
    /// Default client/server address when none is provided.
    public static let defaultAddress = "127.0.0.1"
    /// Default UDP port when none is provided.
    public static let defaultPort: UInt16 = 12567

    /// Indicates whether we should boot the server or the client.
    public var mode: BoxRuntimeMode
    /// Remote address (client) or preferred bind address (server).
    public var address: String
    /// UDP port used for binding (server) or remote connection (client).
    public var port: UInt16
    /// Metadata explaining how the port was resolved.
    public var portOrigin: PortOrigin
    /// Optional path to a configuration PLIST file.
    public var configurationPath: String?
    /// Flag indicating whether the admin channel should be enabled (server mode).
    public var adminChannelEnabled: Bool
    /// Desired logging level for swift-log.
    public var logLevel: Logger.Level
    /// Metadata explaining how the log level was resolved.
    public var logLevelOrigin: LogLevelOrigin
    /// Optional client action that should be executed after the handshake.
    public var clientAction: BoxClientAction

    /// Creates a new bundle of runtime options.
    /// - Parameters:
    ///   - mode: Server or client mode.
    ///   - address: Remote or bind address.
    ///   - port: UDP port to use.
    ///   - configurationPath: Optional PLIST configuration file.
    ///   - adminChannelEnabled: Whether the server admin channel should be enabled (ignored for client).
    ///   - logLevel: Logging level used by swift-log.
    ///   - portOrigin: Origin of the port value (default, CLI, env, config, positional).
    ///   - logLevelOrigin: Origin of the log level value (default, CLI, config).
    ///   - clientAction: Action executed by the client after the handshake.
    public init(
        mode: BoxRuntimeMode,
        address: String,
        port: UInt16,
        portOrigin: PortOrigin,
        configurationPath: String?,
        adminChannelEnabled: Bool,
        logLevel: Logger.Level,
        logLevelOrigin: LogLevelOrigin,
        clientAction: BoxClientAction = .handshake
    ) {
        self.mode = mode
        self.address = address
        self.port = port
        self.portOrigin = portOrigin
        self.configurationPath = configurationPath
        self.adminChannelEnabled = adminChannelEnabled
        self.logLevel = logLevel
        self.logLevelOrigin = logLevelOrigin
        self.clientAction = clientAction
    }
}

/// Errors thrown while bootstrapping the runtime.
public enum BoxRuntimeError: Error, CustomStringConvertible {
    /// Raised when the current platform is unsupported.
    case unsupportedPlatform(String)
    /// Raised when a configuration file could not be parsed.
    case configurationLoadFailed(URL)
    /// Raised when the admin channel cannot be initialised.
    case adminChannelUnavailable(String)
    /// Raised when an operation is not permitted (e.g. running as root).
    case forbiddenOperation(String)

    /// Human readable description used for CLI diagnostics.
    public var description: String {
        switch self {
        case .unsupportedPlatform(let reason):
            return "unsupported platform: \(reason)"
        case .configurationLoadFailed(let url):
            return "failed to load configuration at \(url.path)"
        case .adminChannelUnavailable(let reason):
            return "admin channel unavailable: \(reason)"
        case .forbiddenOperation(let reason):
            return "forbidden operation: \(reason)"
        }
    }
}

public extension Logger.Level {
    /// Parses a log level string coming from the CLI into a swift-log level.
    /// Values falling back to `.info` if the input is missing or not recognised.
    /// - Parameter logLevelString: Optional string supplied by the user.
    init(logLevelString: String?) {
        guard let value = logLevelString?.lowercased() else {
            self = .info
            return
        }
        switch value {
        case "trace":
            self = .trace
        case "debug":
            self = .debug
        case "warn":
            self = .warning
        case "error":
            self = .error
        case "critical":
            self = .critical
        default:
            self = .info
        }
    }
}
