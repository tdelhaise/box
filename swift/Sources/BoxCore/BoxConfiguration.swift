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
    /// Stable node UUID persisted on disk.
    public var nodeUUID: UUID

    /// Attempts to load the server configuration from a PLIST file.
    /// - Parameter url: Location of the PLIST file.
    /// - Returns: A configuration instance when decoding succeeds, otherwise `nil`.
    public static func load(from url: URL) throws -> BoxServerConfiguration? {
        if !FileManager.default.fileExists(atPath: url.path) {
            return try writeDefaultServerConfiguration(to: url)
        }

        let data = try Data(contentsOf: url)
        if data.isEmpty {
            return try writeDefaultServerConfiguration(to: url)
        }

        let decoder = PropertyListDecoder()
        var plist = try decoder.decode(ServerConfigPlist.self, from: data)
        var mutated = false
        if plist.nodeUUID == nil || UUID(uuidString: plist.nodeUUID ?? "") == nil {
            plist.nodeUUID = UUID().uuidString
            mutated = true
        }
        if mutated {
            try persist(plist: plist, to: url)
        }
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
        self.nodeUUID = UUID(uuidString: plist.nodeUUID ?? "") ?? UUID()
    }

    private struct ServerConfigPlist: Codable {
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
        var nodeUUID: String?

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
            case nodeUUID = "node_uuid"
        }
    }

    private static func writeDefaultServerConfiguration(to url: URL) throws -> BoxServerConfiguration {
        let defaultPlist = ServerConfigPlist(
            port: BoxRuntimeOptions.defaultPort,
            logLevel: Logger.Level.info.rawValue,
            logTarget: "stderr",
            transport: "clear",
            transportStatus: nil,
            transportPut: nil,
            transportGet: nil,
            preShareKey: nil,
            noisePattern: nil,
            adminChannelEnabled: true,
            nodeUUID: UUID().uuidString
        )
        try persist(plist: defaultPlist, to: url)
        return BoxServerConfiguration(plist: defaultPlist)
    }

    private static func persist(plist: ServerConfigPlist, to url: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let data = try encoder.encode(plist)
        try ensureConfigurationParentDirectoryExists(for: url)
        try data.write(to: url, options: .atomic)
        #if !os(Windows)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: url.path)
        #endif
    }
}

/// Runtime representation of the client configuration loaded from a PLIST file.
public struct BoxClientConfiguration: Sendable {
    /// Logging level override when present.
    public var logLevel: Logger.Level?
    /// Logging target string.
    public var logTarget: String?
    /// Default server address override.
    public var address: String?
    /// Default server port override.
    public var port: UInt16?
    /// Stable node UUID persisted on disk for this client instance.
    public var nodeUUID: UUID?

    /// Attempts to load the client configuration from a PLIST file.
    public static func load(from url: URL) throws -> BoxClientConfiguration? {
        if !FileManager.default.fileExists(atPath: url.path) {
            return try writeDefaultClientConfiguration(to: url)
        }
        let data = try Data(contentsOf: url)
        if data.isEmpty {
            return try writeDefaultClientConfiguration(to: url)
        }
        let decoder = PropertyListDecoder()
        var plist = try decoder.decode(ClientConfigPlist.self, from: data)
        var mutated = false
        if plist.nodeUUID == nil || UUID(uuidString: plist.nodeUUID ?? "") == nil {
            plist.nodeUUID = UUID().uuidString
            mutated = true
        }
        if mutated {
            try persist(plist: plist, to: url)
        }
        return BoxClientConfiguration(plist: plist)
    }

    /// Convenience helper loading the default client configuration if present.
    /// - Parameter explicitPath: Optional CLI `--config` path that should take precedence.
    public static func loadDefault(explicitPath: String?) throws -> BoxClientConfiguration? {
        guard let url = BoxPaths.clientConfigurationURL(explicitPath: explicitPath) else {
            return nil
        }
        return try load(from: url)
    }

    private init(plist: ClientConfigPlist) {
        self.logLevel = plist.logLevel.flatMap { Logger.Level(logLevelString: $0) }
        self.logTarget = plist.logTarget
        self.address = plist.address
        self.port = plist.port
        self.nodeUUID = plist.nodeUUID.flatMap { UUID(uuidString: $0) }
    }

    private struct ClientConfigPlist: Codable {
        var logLevel: String?
        var logTarget: String?
        var address: String?
        var port: UInt16?
        var nodeUUID: String?

        enum CodingKeys: String, CodingKey {
            case logLevel = "log_level"
            case logTarget = "log_target"
            case address
            case port
            case nodeUUID = "node_uuid"
        }
    }

    private static func writeDefaultClientConfiguration(to url: URL) throws -> BoxClientConfiguration {
        let defaultPlist = ClientConfigPlist(
            logLevel: Logger.Level.info.rawValue,
            logTarget: "stderr",
            address: BoxRuntimeOptions.defaultAddress,
            port: BoxRuntimeOptions.defaultPort,
            nodeUUID: UUID().uuidString
        )
        try persist(plist: defaultPlist, to: url)
        return BoxClientConfiguration(plist: defaultPlist)
    }

    private static func persist(plist: ClientConfigPlist, to url: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let data = try encoder.encode(plist)
        try ensureConfigurationParentDirectoryExists(for: url)
        try data.write(to: url, options: .atomic)
        #if !os(Windows)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: url.path)
        #endif
    }
}

private func ensureConfigurationParentDirectoryExists(for url: URL) throws {
    let directoryURL = url.deletingLastPathComponent()
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
        return
    }
    #if !os(Windows)
    let attributes: [FileAttributeKey: Any]? = [.posixPermissions: NSNumber(value: Int16(0o700))]
    #else
    let attributes: [FileAttributeKey: Any]? = nil
    #endif
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: attributes)
}
