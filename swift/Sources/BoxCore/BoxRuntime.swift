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
    /// Resolve a Location Service record for the supplied node identifier.
    case locate(node: UUID)
}

/// Aggregates runtime options shared between the client and the server entry points.
public struct BoxRuntimeOptions: Sendable {
    /// Describes a remote root server endpoint that can handle locate requests.
    public struct RootServer: Sendable, Equatable, Hashable {
        public var address: String
        public var port: UInt16

        public init(address: String, port: UInt16) {
            self.address = address
            self.port = port
        }
    }

    /// Identifies how the effective address was determined.
    public enum AddressOrigin: Sendable {
        case `default`
        case cliFlag
        case configuration
    }

    /// Indicates how the effective port value was obtained.
    public enum PortOrigin: Sendable {
        case `default`
        case cliFlag
        case environment
        case configuration
        case positional
    }

    /// Indicates how the effective log level was determined.
    public enum LogLevelOrigin: Sendable {
        case `default`
        case cliFlag
        case configuration
        case runtime
    }

    /// Indicates how the effective log target was determined.
    public enum LogTargetOrigin: Sendable {
        case `default`
        case cliFlag
        case configuration
        case runtime
    }

    /// Origin of the port mapping preference.
    public enum PortMappingOrigin: Sendable {
        case `default`
        case cliFlag
        case configuration
    }

    /// Identifies how a manual external address override was provided.
    public enum ExternalAddressOrigin: Sendable {
        case `default`
        case cliFlag
        case configuration
    }

    /// Default client address when none is provided.
    public static let defaultClientAddress = "127.0.0.1"
    /// Default server bind address when none is provided.
    public static let defaultServerBindAddress = "0.0.0.0"
    /// Backward compatibility alias for the historic default (client) address.
    public static let defaultAddress = BoxRuntimeOptions.defaultClientAddress
    /// Default UDP port when none is provided.
    public static let defaultPort: UInt16 = 12567

    /// Returns the default log target for the provided runtime mode.
    /// - Parameter mode: Client or server mode.
    /// - Returns: File-based log target when the logs directory is resolvable, otherwise stderr.
    public static func defaultLogTarget(for mode: BoxRuntimeMode) -> BoxLogTarget {
        let role: BoxPaths.LogFileRole = (mode == .server) ? .server : .client
        if let url = BoxPaths.defaultLogFileURL(role: role) {
            return .file(url.path)
        }
        return .stderr
    }

    /// Indicates whether we should boot the server or the client.
    public var mode: BoxRuntimeMode
    /// Remote address (client) or preferred bind address (server).
    public var address: String
    /// UDP port used for binding (server) or remote connection (client).
    public var port: UInt16
    /// Metadata explaining how the port was resolved.
    public var portOrigin: PortOrigin
    /// Metadata explaining how the address was resolved.
    public var addressOrigin: AddressOrigin
    /// Optional path to a configuration PLIST file.
    public var configurationPath: String?
    /// Flag indicating whether the admin channel should be enabled (server mode).
    public var adminChannelEnabled: Bool
    /// Desired logging level for swift-log.
    public var logLevel: Logger.Level
    /// Desired logging target for Puppy.
    public var logTarget: BoxLogTarget
    /// Metadata explaining how the log level was resolved.
    public var logLevelOrigin: LogLevelOrigin
    /// Metadata explaining how the log target was resolved.
    public var logTargetOrigin: LogTargetOrigin
    /// Optional client action that should be executed after the handshake.
    public var clientAction: BoxClientAction
    /// Stable node identifier assigned to this runtime.
    public var nodeId: UUID
    /// Stable user identifier on behalf of which this runtime acts.
    public var userId: UUID
    /// Indicates whether automatic port mapping (PCP/NAT-PMP/UPnP) was requested.
    public var portMappingRequested: Bool
    /// Indicates how the port mapping preference was obtained.
    public var portMappingOrigin: PortMappingOrigin
    /// List of configured root servers used by the client when fanning out locate requests.
    public var rootServers: [RootServer]
    /// Manual external IP (if provided by the operator).
    public var externalAddressOverride: String?
    /// Manual external port (defaults to the runtime port when absent).
    public var externalPortOverride: UInt16?
    /// Origin of the manual external address override.
    public var externalAddressOrigin: ExternalAddressOrigin
    /// Set of queues that should retain messages after GET operations.
    public var permanentQueues: Set<String>

    /// Creates a new bundle of runtime options.
    /// - Parameters:
    ///   - mode: Server or client mode.
    ///   - address: Remote or bind address.
    ///   - port: UDP port to use.
    ///   - configurationPath: Optional PLIST configuration file.
    ///   - adminChannelEnabled: Whether the server admin channel should be enabled (ignored for client).
    ///   - logLevel: Logging level used by swift-log.
    ///   - logTarget: Logging destination used by Puppy.
    ///   - portOrigin: Origin of the port value (default, CLI, env, config, positional).
    ///   - logLevelOrigin: Origin of the log level value (default, CLI, config).
    ///   - logTargetOrigin: Origin of the log target value (default, CLI, config).
    ///   - nodeId: Stable identifier describing the local machine.
    ///   - userId: Stable identifier describing the user operating the client/server.
    ///   - clientAction: Action executed by the client after the handshake.
    public init(
        mode: BoxRuntimeMode,
        address: String,
        port: UInt16,
        portOrigin: PortOrigin,
        addressOrigin: AddressOrigin,
        configurationPath: String?,
        adminChannelEnabled: Bool,
        logLevel: Logger.Level,
        logTarget: BoxLogTarget,
        logLevelOrigin: LogLevelOrigin,
        logTargetOrigin: LogTargetOrigin,
        nodeId: UUID,
        userId: UUID,
        portMappingRequested: Bool,
        clientAction: BoxClientAction = .handshake,
        portMappingOrigin: PortMappingOrigin,
        externalAddressOverride: String? = nil,
        externalPortOverride: UInt16? = nil,
        externalAddressOrigin: ExternalAddressOrigin = .default,
        permanentQueues: Set<String> = [],
        rootServers: [RootServer] = []
    ) {
        self.mode = mode
        self.address = address
        self.port = port
        self.portOrigin = portOrigin
        self.addressOrigin = addressOrigin
        self.configurationPath = configurationPath
        self.adminChannelEnabled = adminChannelEnabled
        self.logLevel = logLevel
        self.logTarget = logTarget
        self.logLevelOrigin = logLevelOrigin
        self.logTargetOrigin = logTargetOrigin
        self.nodeId = nodeId
        self.userId = userId
        self.portMappingRequested = portMappingRequested
        self.portMappingOrigin = portMappingOrigin
        self.clientAction = clientAction
        self.externalAddressOverride = externalAddressOverride
        self.externalPortOverride = externalPortOverride
        self.externalAddressOrigin = externalAddressOrigin
        self.permanentQueues = permanentQueues
        self.rootServers = rootServers
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
    /// Raised when storage prerequisites (queues, directories) are not met.
    case storageUnavailable(String)

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
        case .storageUnavailable(let reason):
            return "storage unavailable: \(reason)"
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
