import Foundation
import Logging

/// Runtime representation of the server configuration loaded from a PLIST file.
public struct BoxServerConfiguration: Sendable {
    /// Port override when present.
    public var port: UInt16?
    /// Logging level override when present.
    public var logLevel: Logger.Level?
    /// Log target string determining the Puppy destination (`stderr|stdout|file:/path`).
    public var logTarget: String?
    /// General transport toggle (`clear` or `noise`).
    public var transportGeneral: String?
    /// Transport override for STATUS commands.
    public var transportStatus: String?
    /// Transport override for PUT commands.
    public var transportPut: String?
    /// Transport override for GET commands.
    public var transportGet: String?
    /// Pre-shared key ASCII string configured for the Noise scaffold.
    public var preShareKey: String?
    /// Noise handshake pattern (`nk`, `ik`, ...).
    public var noisePattern: String?
    /// Optional flag enabling/disabling the admin channel.
    public var adminChannelEnabled: Bool?

    /// Attempts to load the server configuration from a PLIST file.
    /// - Parameter url: Location of the PLIST file.
    /// - Returns: A configuration instance when decoding succeeds, otherwise `nil`.
    public static func load(from url: URL) throws -> BoxServerConfiguration? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        if data.isEmpty {
            return nil
        }
        let decoder = PropertyListDecoder()
        let plist = try decoder.decode(ServerConfigPlist.self, from: data)
        return BoxServerConfiguration(plist: plist)
    }

    /// Convenience helper loading the default server configuration if present.
    /// - Parameter explicitPath: Optional CLI `--config` path that should take precedence.
    /// - Returns: A configuration instance when decoding succeeds, otherwise `nil`.
    public static func loadDefault(explicitPath: String?) throws -> BoxServerConfiguration? {
        guard let url = BoxPaths.serverConfigurationURL(explicitPath: explicitPath) else {
            return nil
        }
        return try load(from: url)
    }

    private init(plist: ServerConfigPlist) {
        self.port = plist.port
        self.logLevel = plist.logLevel.flatMap { Logger.Level(logLevelString: $0) }
        self.logTarget = plist.logTarget
        self.transportGeneral = plist.transport
        self.transportStatus = plist.transportStatus
        self.transportPut = plist.transportPut
        self.transportGet = plist.transportGet
        self.preShareKey = plist.preShareKey
        self.noisePattern = plist.noisePattern
        self.adminChannelEnabled = plist.adminChannelEnabled
    }

    private struct ServerConfigPlist: Decodable {
        var port: UInt16?
        var logLevel: String?
        var logTarget: String?
        var transport: String?
        var transportStatus: String?
        var transportPut: String?
        var transportGet: String?
        var preShareKey: String?
        var noisePattern: String?
        var adminChannelEnabled: Bool?

        enum CodingKeys: String, CodingKey {
            case port
            case logLevel = "log_level"
            case logTarget = "log_target"
            case transport
            case transportStatus = "transport_status"
            case transportPut = "transport_put"
            case transportGet = "transport_get"
            case preShareKey = "pre_share_key"
            case noisePattern = "noise_pattern"
            case adminChannelEnabled = "admin_channel"
        }
    }
}
