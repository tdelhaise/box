import Foundation
import Logging

/// Represents the merged Box configuration loaded from `Box.plist`.
public struct BoxConfiguration: Sendable {
    /// Common identifiers shared between the client and the server.
    public struct Common: Sendable {
        /// Stable identifier of the local machine on the Box network.
        public var nodeUUID: UUID
        /// Stable identifier of the user on whose behalf the machine operates.
        public var userUUID: UUID
    }

    /// Nested configuration specific to the server runtime.
    public struct Server: Sendable {
        public var port: UInt16?
        public var logLevel: Logger.Level?
        public var logTarget: String?
        public var transportGeneral: String?
        public var transportStatus: String?
        public var transportPut: String?
        public var transportGet: String?
        public var preShareKey: String?
        public var noisePattern: String?
        public var adminChannelEnabled: Bool?
        public var portMappingEnabled: Bool?
        public var externalAddress: String?
        public var externalPort: UInt16?

        public init(
            port: UInt16? = nil,
            logLevel: Logger.Level? = nil,
            logTarget: String? = nil,
            transportGeneral: String? = nil,
            transportStatus: String? = nil,
            transportPut: String? = nil,
            transportGet: String? = nil,
            preShareKey: String? = nil,
            noisePattern: String? = nil,
            adminChannelEnabled: Bool? = nil,
            portMappingEnabled: Bool? = nil,
            externalAddress: String? = nil,
            externalPort: UInt16? = nil
        ) {
            self.port = port
            self.logLevel = logLevel
            self.logTarget = logTarget
            self.transportGeneral = transportGeneral
            self.transportStatus = transportStatus
            self.transportPut = transportPut
            self.transportGet = transportGet
            self.preShareKey = preShareKey
            self.noisePattern = noisePattern
            self.adminChannelEnabled = adminChannelEnabled
            self.portMappingEnabled = portMappingEnabled
            self.externalAddress = externalAddress
            self.externalPort = externalPort
        }
    }

    /// Nested configuration specific to the client runtime.
    public struct Client: Sendable {
        public var logLevel: Logger.Level?
        public var logTarget: String?
        public var address: String?
        public var port: UInt16?

        public init(
            logLevel: Logger.Level? = nil,
            logTarget: String? = nil,
            address: String? = nil,
            port: UInt16? = nil
        ) {
            self.logLevel = logLevel
            self.logTarget = logTarget
            self.address = address
            self.port = port
        }
    }

    /// Common section shared by every runtime.
    public var common: Common
    /// Server-specific section.
    public var server: Server
    /// Client-specific section.
    public var client: Client

    public init(common: Common, server: Server, client: Client) {
        self.common = common
        self.server = server
        self.client = client
    }
}

/// Result returned when loading a configuration from disk.
public struct BoxConfigurationLoadResult: Sendable {
    /// Parsed configuration.
    public var configuration: BoxConfiguration
    /// Location of the configuration file on disk.
    public var url: URL
    /// Indicates whether the file was created (or fully rewritten) during the load process.
    public var wasCreated: Bool
}

public extension BoxConfiguration {
    /// Loads the configuration from disk, creating a default one when missing.
    /// - Parameter url: Location of the PLIST file.
    /// - Returns: Parsed configuration alongside metadata describing creation status.
    static func load(from url: URL) throws -> BoxConfigurationLoadResult {
        let fileManager = FileManager.default
        var wasCreated = false
        let baseDirectory = url.deletingLastPathComponent()

        if !fileManager.fileExists(atPath: url.path) {
            let defaultPlist = ConfigurationPlist.default(configurationURL: url)
            try persist(plist: defaultPlist, to: url)
            wasCreated = true
        }

        let data = try Data(contentsOf: url)
        if data.isEmpty {
            let defaultPlist = ConfigurationPlist.default(configurationURL: url)
            try persist(plist: defaultPlist, to: url)
            return BoxConfigurationLoadResult(
                configuration: BoxConfiguration(plist: defaultPlist),
                url: url,
                wasCreated: true
            )
        }

        let decoder = PropertyListDecoder()
        var plist = try decoder.decode(ConfigurationPlist.self, from: data)
        var mutated = false

        if plist.common == nil {
            plist.common = ConfigurationPlist.Common(
                nodeUUID: UUID().uuidString,
                userUUID: UUID().uuidString
            )
            mutated = true
        } else {
            if let node = plist.common?.nodeUUID.flatMap(UUID.init(uuidString:)).map({ $0.uuidString }) {
                plist.common?.nodeUUID = node
            } else {
                plist.common?.nodeUUID = UUID().uuidString
                mutated = true
            }
            if let user = plist.common?.userUUID.flatMap(UUID.init(uuidString:)).map({ $0.uuidString }) {
                plist.common?.userUUID = user
            } else {
                plist.common?.userUUID = UUID().uuidString
                mutated = true
            }
        }

        if plist.client == nil {
            plist.client = ConfigurationPlist.Client.default(baseDirectory: baseDirectory)
            mutated = true
        }
        if plist.server == nil {
            plist.server = ConfigurationPlist.Server.default(baseDirectory: baseDirectory)
            mutated = true
        } else if plist.server?.portMapping == nil {
            plist.server?.portMapping = false
            mutated = true
        }

        if mutated {
            try persist(plist: plist, to: url)
        }

        return BoxConfigurationLoadResult(
            configuration: BoxConfiguration(plist: plist),
            url: url,
            wasCreated: wasCreated
        )
    }

    /// Loads the configuration from the default path, falling back to `Box.plist` under `~/.box`.
    /// - Parameter explicitPath: Optional CLI supplied path.
    /// - Returns: Parsed configuration when the location could be resolved.
    static func loadDefault(explicitPath: String?) throws -> BoxConfigurationLoadResult? {
        guard let url = BoxPaths.configurationURL(explicitPath: explicitPath) else {
            return nil
        }
        return try load(from: url)
    }
}

// MARK: - Codable plumbing

private extension BoxConfiguration {
    init(plist: ConfigurationPlist) {
        let defaultBaseDirectory = BoxPaths.boxDirectory()
        let commonSection = plist.common ?? ConfigurationPlist.Common(nodeUUID: UUID().uuidString, userUUID: UUID().uuidString)
        let nodeUUID = commonSection.nodeUUID.flatMap(UUID.init(uuidString:)) ?? UUID()
        let userUUID = commonSection.userUUID.flatMap(UUID.init(uuidString:)) ?? UUID()
        self.common = Common(nodeUUID: nodeUUID, userUUID: userUUID)

        let serverSection = plist.server ?? ConfigurationPlist.Server.default(baseDirectory: defaultBaseDirectory)
        self.server = Server(
            port: serverSection.port,
            logLevel: serverSection.logLevel.flatMap { Logger.Level(logLevelString: $0) },
            logTarget: serverSection.logTarget,
            transportGeneral: serverSection.transport,
            transportStatus: serverSection.transportStatus,
            transportPut: serverSection.transportPut,
            transportGet: serverSection.transportGet,
            preShareKey: serverSection.preShareKey,
            noisePattern: serverSection.noisePattern,
            adminChannelEnabled: serverSection.adminChannelEnabled,
            portMappingEnabled: serverSection.portMapping,
            externalAddress: serverSection.externalAddress,
            externalPort: serverSection.externalPort
        )

        let clientSection = plist.client ?? ConfigurationPlist.Client.default(baseDirectory: defaultBaseDirectory)
        self.client = Client(
            logLevel: clientSection.logLevel.flatMap { Logger.Level(logLevelString: $0) },
            logTarget: clientSection.logTarget,
            address: clientSection.address,
            port: clientSection.port
        )
    }

    func makePlist() -> ConfigurationPlist {
        ConfigurationPlist(
            common: ConfigurationPlist.Common(
                nodeUUID: common.nodeUUID.uuidString.uppercased(),
                userUUID: common.userUUID.uuidString.uppercased()
            ),
            server: ConfigurationPlist.Server(
                port: server.port,
                logLevel: server.logLevel?.rawValue,
                logTarget: server.logTarget,
                transport: server.transportGeneral,
                transportStatus: server.transportStatus,
                transportPut: server.transportPut,
                transportGet: server.transportGet,
                preShareKey: server.preShareKey,
                noisePattern: server.noisePattern,
                adminChannelEnabled: server.adminChannelEnabled,
                portMapping: server.portMappingEnabled,
                externalAddress: server.externalAddress,
                externalPort: server.externalPort
            ),
            client: ConfigurationPlist.Client(
                logLevel: client.logLevel?.rawValue,
                logTarget: client.logTarget,
                address: client.address,
                port: client.port
            )
        )
    }
}

private struct ConfigurationPlist: Codable {
    struct Common: Codable {
        var nodeUUID: String?
        var userUUID: String?

        enum CodingKeys: String, CodingKey {
            case nodeUUID = "node_uuid"
            case userUUID = "user_uuid"
        }
    }

    struct Server: Codable {
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
        var portMapping: Bool?
        var externalAddress: String?
        var externalPort: UInt16?

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
            case portMapping = "port_mapping"
            case externalAddress = "external_address"
            case externalPort = "external_port"
        }

        static func `default`(baseDirectory: URL? = nil) -> Server {
            let targetString = defaultLogTargetString(for: .server, baseDirectory: baseDirectory)
            return Server(
                port: BoxRuntimeOptions.defaultPort,
                logLevel: Logger.Level.info.rawValue,
                logTarget: targetString,
                transport: "clear",
                transportStatus: nil,
                transportPut: nil,
                transportGet: nil,
                preShareKey: nil,
                noisePattern: nil,
                adminChannelEnabled: true,
                portMapping: false,
                externalAddress: nil,
                externalPort: nil
            )
        }
    }

    struct Client: Codable {
        var logLevel: String?
        var logTarget: String?
        var address: String?
        var port: UInt16?

        enum CodingKeys: String, CodingKey {
            case logLevel = "log_level"
            case logTarget = "log_target"
            case address
            case port
        }

        static func `default`(baseDirectory: URL? = nil) -> Client {
            let targetString = defaultLogTargetString(for: .client, baseDirectory: baseDirectory)
            return Client(
                logLevel: Logger.Level.info.rawValue,
                logTarget: targetString,
                address: BoxRuntimeOptions.defaultClientAddress,
                port: BoxRuntimeOptions.defaultPort
            )
        }
    }

    var common: Common?
    var server: Server?
    var client: Client?

    static func `default`(configurationURL: URL? = nil) -> ConfigurationPlist {
        let baseDirectory = configurationURL?.deletingLastPathComponent()
        return ConfigurationPlist(
            common: Common(
                nodeUUID: UUID().uuidString,
                userUUID: UUID().uuidString
            ),
            server: Server.default(baseDirectory: baseDirectory),
            client: Client.default(baseDirectory: baseDirectory)
        )
    }

    private static func defaultLogTargetString(for mode: BoxRuntimeMode, baseDirectory: URL?) -> String {
        let defaultTarget = BoxRuntimeOptions.defaultLogTarget(for: mode)
        if case .file = defaultTarget {
            return defaultTarget.description
        }
        if let baseDirectory {
            let fileName = (mode == .server) ? "boxd.log" : "box.log"
            let fallbackPath = baseDirectory.appendingPathComponent(fileName, isDirectory: false).path
            return "file:\(fallbackPath)"
        }
        return defaultTarget.description
    }
}

private extension BoxLogTarget {
    /// Provides a serialisable representation suitable for plist storage.
    var description: String {
        switch self {
        case .stderr:
            return "stderr"
        case .stdout:
            return "stdout"
        case .file(let path):
            return "file:\(path)"
        }
    }
}

private func persist(plist: ConfigurationPlist, to url: URL) throws {
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .xml
    let data = try encoder.encode(plist)
    try ensureConfigurationParentDirectoryExists(for: url)
    try data.write(to: url, options: .atomic)
#if !os(Windows)
    try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: url.path)
#endif
}

public extension BoxConfiguration {
    /// Persists the configuration back to disk.
    /// - Parameter url: Destination path.
    func save(to url: URL) throws {
        try persist(plist: makePlist(), to: url)
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
