import ArgumentParser
import BoxClient
import BoxCore
import BoxServer
import Foundation
import Logging

#if os(Linux)
import Glibc
#elseif os(Windows)
import CRT
#else
import Darwin
#endif

/// Represents the optional client-side bind override parsed from natural CLI syntax.
fileprivate struct BindingSpecification {
    /// Optional local address the client should bind to before sending packets.
    var address: String?
    /// Optional UDP port the client should bind to when creating the socket.
    var port: UInt16?
}

/// Stream-based helper that consumes natural-language tokens emitted by swift-argument-parser.
fileprivate struct NaturalLanguageTokenStream {
    private let tokens: [String]
    private var index: Int = 0

    /// Creates a new stream backed by the provided command-line tokens.
    /// - Parameter tokens: Array of tokens captured by swift-argument-parser.
    init(tokens: [String]) {
        self.tokens = tokens
    }

    /// Indicates whether unread tokens remain in the stream.
    var hasRemaining: Bool {
        index < tokens.count
    }

    /// Human-readable description of the remaining tokens (used when reporting errors).
    var remainingDescription: String {
        guard index < tokens.count else { return "<none>" }
        return tokens[index...].joined(separator: " ")
    }

    /// Consumes the next token when it matches the supplied keyword (case-insensitive).
    /// - Parameter keyword: Keyword that should be matched.
    /// - Returns: `true` when the token was consumed, `false` otherwise.
    mutating func consumeKeyword(_ keyword: String) -> Bool {
        guard let candidate = peekToken() else { return false }
        if candidate.caseInsensitiveCompare(keyword) == .orderedSame {
            index += 1
            return true
        }
        return false
    }

    /// Ensures the next token matches the supplied keyword.
    /// - Parameter keyword: Expected keyword.
    mutating func expectKeyword(_ keyword: String) throws {
        if !consumeKeyword(keyword) {
            if let next = peekToken() {
                throw ValidationError("Expected keyword '\(keyword)' before '\(next)'.")
            } else {
                throw ValidationError("Expected keyword '\(keyword)' but reached end of command.")
            }
        }
    }

    /// Returns the next token, throwing when none remain.
    /// - Parameter errorMessage: Error reported when the stream is exhausted.
    mutating func nextValue(_ errorMessage: String) throws -> String {
        guard index < tokens.count else {
            throw ValidationError(errorMessage)
        }
        let value = tokens[index]
        index += 1
        return value
    }

    /// Parses an optional binding specifier (`from [addr] port 1234`) at the current position.
    /// - Returns: Parsed binding specification (empty when absent).
    mutating func parseBindingSpecifier() throws -> BindingSpecification {
        guard consumeKeyword("from") else {
            return BindingSpecification(address: nil, port: nil)
        }

        var address: String?
        if let next = peekToken(), !next.lowercased().elementsEqual("port") {
            address = stripIPv6Brackets(try nextValue("Expected address after 'from'."))
        }

        var port: UInt16?
        if consumeKeyword("port") {
            let token = try nextValue("Expected port number after 'port'.")
            guard let parsed = UInt16(token) else {
                throw ValidationError("'\(token)' is not a valid UDP port.")
            }
            port = parsed
        }

        return BindingSpecification(address: address, port: port)
    }

    /// Returns the next token without consuming it.
    private func peekToken() -> String? {
        guard index < tokens.count else { return nil }
        return tokens[index]
    }

    /// Strips IPv6 brackets from the supplied token when present.
    private func stripIPv6Brackets(_ token: String) -> String {
        if token.hasPrefix("["), token.hasSuffix("]"), token.count >= 2 {
            let start = token.index(after: token.startIndex)
            let end = token.index(before: token.endIndex)
            return String(token[start..<end])
        }
        return token
    }
}

/// Describes the target supplied to natural-language subcommands (PUT/GET/LOCATE).
fileprivate struct NaturalTarget {
    /// Differentiates the supported syntaxes.
    enum Kind {
        case uuid(UUID)
        case boxURL(BoxURL)
    }

    /// Captures the parsed `box://` representation.
    struct BoxURL {
        /// Identifies how the node segment should be interpreted.
        enum NodeSpecifier {
            case specific(UUID)
            case wildcard
        }

        /// UUID of the user portion (`box://<user>@...`).
        var userUUID: UUID
        /// Node selector extracted from the URL.
        var nodeSpecifier: NodeSpecifier
        /// Optional UDP port override supplied via `:<port>`.
        var port: UInt16?
        /// Optional queue component derived from `/queue`.
        var queue: String?
    }

    /// Underlying representation of the target.
    var kind: Kind
    /// Optional queue hint discovered while parsing the expression.
    var queueComponent: String?
    /// Optional port override embedded in the expression.
    var portOverride: UInt16?

    /// Creates a new target description from the raw CLI token.
    /// - Parameter token: Raw token captured by swift-argument-parser.
    init(token: String) throws {
        if token.lowercased().hasPrefix("box://") {
            let parsed = try NaturalTarget.parseBoxURL(token)
            self.kind = .boxURL(parsed)
            self.queueComponent = parsed.queue
            self.portOverride = parsed.port
        } else if let uuid = UUID(uuidString: token) {
            self.kind = .uuid(uuid)
            self.queueComponent = nil
            self.portOverride = nil
        } else {
            throw ValidationError("'\(token)' is not a valid UUID or box:// target.")
        }
    }

    /// Human-readable description used when reporting errors.
    var debugDescription: String {
        switch kind {
        case .uuid(let uuid):
            return uuid.uuidString
        case .boxURL(let url):
            let nodePart: String
            switch url.nodeSpecifier {
            case .specific(let nodeUUID):
                nodePart = nodeUUID.uuidString
            case .wildcard:
                nodePart = "*"
            }
            var builder = "box://\(url.userUUID.uuidString)@\(nodePart)"
            if let port = url.port {
                builder += ":\(port)"
            }
            if let queue = url.queue, !queue.isEmpty {
                builder += "/\(queue)"
            }
            return builder
        }
    }

    /// Parses a `box://` styled token.
    /// - Parameter token: Raw CLI token beginning with `box://`.
    /// - Returns: Parsed URL structure.
    private static func parseBoxURL(_ token: String) throws -> BoxURL {
        let prefix = "box://"
        let remainder = String(token.dropFirst(prefix.count))
        guard let atIndex = remainder.firstIndex(of: "@") else {
            throw ValidationError("box:// targets must include a '@' separating user and node identifiers.")
        }

        let userPart = String(remainder[..<atIndex])
        guard let userUUID = UUID(uuidString: userPart) else {
            throw ValidationError("'\(userPart)' is not a valid user UUID in box:// target.")
        }

        var nodeAndRest = String(remainder[remainder.index(after: atIndex)...])
        var queueComponent: String?
        if let slashIndex = nodeAndRest.firstIndex(of: "/") {
            let queueSubstring = nodeAndRest[nodeAndRest.index(after: slashIndex)...]
            queueComponent = queueSubstring.isEmpty ? nil : String(queueSubstring)
            nodeAndRest = String(nodeAndRest[..<slashIndex])
        }

        var port: UInt16?
        if let colonIndex = nodeAndRest.lastIndex(of: ":") {
            let portSubstring = nodeAndRest[nodeAndRest.index(after: colonIndex)...]
            guard !portSubstring.isEmpty, let parsed = UInt16(portSubstring) else {
                throw ValidationError("'\(portSubstring)' is not a valid port in box:// target.")
            }
            port = parsed
            nodeAndRest = String(nodeAndRest[..<colonIndex])
        }

        let nodeSpecifier: BoxURL.NodeSpecifier
        if nodeAndRest == "*" {
            nodeSpecifier = .wildcard
        } else if let nodeUUID = UUID(uuidString: nodeAndRest) {
            nodeSpecifier = .specific(nodeUUID)
        } else {
            throw ValidationError("'\(nodeAndRest)' is not a valid node UUID in box:// target.")
        }

        let normalizedQueue = queueComponent?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return BoxURL(userUUID: userUUID, nodeSpecifier: nodeSpecifier, port: port, queue: normalizedQueue)
    }
}

/// Lightweight cache that exposes Location Service records stored on disk.
fileprivate final class LocationCache {
    private let directory: URL?
    private let decoder = JSONDecoder()
    private let fileManager = FileManager.default
    private var nodeRecords: [UUID: LocationServiceNodeRecord] = [:]
    private var userRecords: [UUID: LocationServiceUserRecord] = [:]

    /// Creates a new cache rooted at the default queue directory.
    init() throws {
        if let root = BoxPaths.queuesDirectory() {
            directory = root.appendingPathComponent("whoswho", isDirectory: true)
        } else {
            directory = nil
        }
    }

    /// Returns the node record stored for the supplied identifier.
    /// - Parameter uuid: Node UUID to load.
    func nodeRecord(for uuid: UUID) throws -> LocationServiceNodeRecord? {
        if let cached = nodeRecords[uuid] {
            return cached
        }
        guard let url = fileURL(for: uuid), fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            let record = try decoder.decode(LocationServiceNodeRecord.self, from: data)
            nodeRecords[uuid] = record
            return record
        } catch let decoding as DecodingError {
            switch decoding {
            case .typeMismatch, .keyNotFound, .valueNotFound, .dataCorrupted:
                return nil
            @unknown default:
                return nil
            }
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return nil
        } catch {
            throw ValidationError("Unable to load node record \(uuid.uuidString): \(error.localizedDescription)")
        }
    }

    /// Returns the user record stored for the supplied identifier.
    /// - Parameter uuid: User UUID to load.
    func userRecord(for uuid: UUID) throws -> LocationServiceUserRecord? {
        if let cached = userRecords[uuid] {
            return cached
        }
        guard let url = fileURL(for: uuid), fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            let record = try decoder.decode(LocationServiceUserRecord.self, from: data)
            userRecords[uuid] = record
            return record
        } catch let decoding as DecodingError {
            switch decoding {
            case .typeMismatch, .keyNotFound, .valueNotFound, .dataCorrupted:
                return nil
            @unknown default:
                return nil
            }
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return nil
        } catch {
            throw ValidationError("Unable to load user record \(uuid.uuidString): \(error.localizedDescription)")
        }
    }

    /// Computes the file path associated with the supplied identifier.
    private func fileURL(for uuid: UUID) -> URL? {
        directory?.appendingPathComponent(uuid.uuidString.uppercased()).appendingPathExtension("json")
    }
}

/// Represents a remote endpoint resolved from the Location Service.
fileprivate struct Endpoint: Hashable {
    /// Node UUID associated with the destination.
    var nodeUUID: UUID
    /// Reachable address (IPv4 or IPv6) exposed by the node.
    var address: String
    /// UDP port advertised for the node.
    var port: UInt16
}

/// Candidate socket address inspected while selecting the preferred endpoint.
fileprivate struct AddressCandidate {
    /// Identifies how the candidate was obtained.
    enum Origin: Int {
        case record = 0
        case portMapping = 1
        case fallback = 2
    }

    /// Address string (IPv4 or IPv6).
    var ip: String
    /// UDP port attached to the candidate.
    var port: UInt16
    /// Optional scope reported by the Location Service.
    var scope: LocationServiceNodeRecord.Address.Scope?
    /// Optional source reported by the Location Service.
    var source: LocationServiceNodeRecord.Address.Source?
    /// Candidate origin (record, port-mapping or fallback).
    var origin: Origin
}

/// Swift Argument Parser entry point that validates CLI options before delegating to the runtime.
@main
public struct BoxCommandParser: AsyncParsableCommand {
    /// Static configuration used by swift-argument-parser (command name and abstract description).
    public static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "box",
            abstract: "Box messaging toolkit (Swift rewrite).",
            subcommands: [Admin.self, InitConfig.self, Register.self, PingRoots.self, Put.self, Get.self, Locate.self]
        )
    }

    /// `box register` — publish node and user records to root servers.
    public struct Register: AsyncParsableCommand {
        public static var configuration: CommandConfiguration {
            CommandConfiguration(
                commandName: "register",
                abstract: "Publish the local node and user records to configured root servers."
            )
        }

        @Option(name: .shortAndLong, help: "Configuration PLIST path (defaults to ~/.box/Box.plist).")
        public var path: String?

        @Option(name: .customLong("address"), help: "Reachable address to advertise for this node (IPv4/IPv6).")
        public var advertisedAddress: String?

        @Option(name: .customLong("port"), help: "UDP port to advertise (defaults to the server/client port).")
        public var advertisedPort: UInt16?

        @Option(name: .customLong("root"), parsing: .unconditionalSingleValue, help: "Root server override (host[:port]). Can be repeated.")
        public var rootOverrides: [String] = []

        public init() {}

        public mutating func run() async throws {
            let configurationURL = try BoxCommandParser.resolveConfigurationURL(path: path)
            let configurationResult = try BoxConfiguration.load(from: configurationURL)
            let configuration = configurationResult.configuration

            let rootServers = try BoxCommandParser.resolveRootServers(configuration: configuration, overrides: rootOverrides)
            guard !rootServers.isEmpty else {
                throw ValidationError("No root servers configured. Use --root or add entries to Box.plist.")
            }

            let keystore = try BoxNoiseKeyStore()
            let nodeIdentity = try await keystore.ensureIdentity(for: .node)

            let userNodes = try loadExistingUserNodes(configuration: configuration)
            let advertisedPortValue = resolveAdvertisedPort(configuration: configuration, override: advertisedPort)
            let addresses = buildAdvertisedAddresses(configuration: configuration, overrideAddress: advertisedAddress, port: advertisedPortValue)

            let nodeRecord = try buildNodeRecord(
                configuration: configuration,
                nodeIdentity: nodeIdentity,
                advertisedPort: advertisedPortValue,
                addresses: addresses
            )

            let userRecord = buildUserRecord(configuration: configuration, existingNodes: userNodes)

            let payloads = [
                try encodeRegisterPayload(uuid: configuration.common.nodeUUID, content: nodeRecord),
                try encodeRegisterPayload(uuid: configuration.common.userUUID, content: userRecord)
            ]

            var successes: [String] = []
            var failures: [(String, Error)] = []

            for root in rootServers {
                do {
                    for payload in payloads {
                        try await send(payload: payload, to: root, configuration: configuration, configurationPath: configurationResult.url.path)
                    }
                    successes.append("\(root.address):\(root.port)")
                } catch {
                    failures.append(("\(root.address):\(root.port)", error))
                }
            }

            if !successes.isEmpty {
                FileHandle.standardOutput.write("Published records to: \(successes.joined(separator: ", "))\n".data(using: .utf8) ?? Data())
            }
            if !failures.isEmpty {
                let lines = failures.map { entry in "Failed to publish to \(entry.0): \(entry.1)" }
                throw ValidationError(lines.joined(separator: "\n"))
            }

            try persistLocalUserRecord(configuration: configuration, userRecord: userRecord)
        }

        // MARK: - Helpers

        private func resolveAdvertisedPort(configuration: BoxConfiguration, override: UInt16?) -> UInt16 {
            if let override {
                return override
            }
            if let serverPort = configuration.server.port {
                return serverPort
            }
            if let clientPort = configuration.client.port {
                return clientPort
            }
            return BoxRuntimeOptions.defaultPort
        }

        private func buildAdvertisedAddresses(configuration: BoxConfiguration, overrideAddress: String?, port: UInt16) -> [LocationServiceNodeRecord.Address] {
            var addresses: [LocationServiceNodeRecord.Address] = []
            func append(_ address: String?, source: LocationServiceNodeRecord.Address.Source) {
                guard let address, !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return
                }
                addresses.append(LocationServiceNodeRecord.Address(ip: address.trimmingCharacters(in: .whitespacesAndNewlines), port: port, scope: .global, source: source))
            }

            append(configuration.server.externalAddress, source: .config)
            append(overrideAddress, source: .manual)
            append(configuration.client.address, source: .config)

            if addresses.isEmpty {
                addresses.append(LocationServiceNodeRecord.Address(ip: "127.0.0.1", port: port, scope: .loopback, source: .manual))
            }

            var unique = [LocationServiceNodeRecord.Address]()
            var seen = Set<LocationServiceNodeRecord.Address>()
            for address in addresses {
                if !seen.contains(address) {
                    seen.insert(address)
                    unique.append(address)
                }
            }
            return unique
        }

        private func buildNodeRecord(
            configuration: BoxConfiguration,
            nodeIdentity: BoxIdentityMaterial,
            advertisedPort: UInt16,
            addresses: [LocationServiceNodeRecord.Address]
        ) throws -> LocationServiceNodeRecord {
            let portMappingEnabled = configuration.server.portMappingEnabled ?? false
            let portMappingOrigin: BoxRuntimeOptions.PortMappingOrigin = configuration.server.portMappingEnabled == nil ? .default : .configuration
            let nodePublicKey = "ed25519:\(hexString(nodeIdentity.publicKey))"
            return LocationServiceNodeRecord.make(
                userUUID: configuration.common.userUUID,
                nodeUUID: configuration.common.nodeUUID,
                port: advertisedPort,
                probedGlobalIPv6: [],
                ipv6Error: nil,
                portMappingEnabled: portMappingEnabled,
                portMappingOrigin: portMappingOrigin,
                additionalAddresses: addresses,
                portMappingExternalIPv4: configuration.server.externalAddress,
                portMappingExternalPort: configuration.server.externalPort ?? advertisedPort,
                nodePublicKey: nodePublicKey
            )
        }

        private func buildUserRecord(configuration: BoxConfiguration, existingNodes: Set<UUID>) -> LocationServiceUserRecord {
            var nodes = existingNodes
            nodes.insert(configuration.common.nodeUUID)
            return LocationServiceUserRecord.make(userUUID: configuration.common.userUUID, nodeUUIDs: Array(nodes))
        }

        private func encodeRegisterPayload<T: Encodable>(uuid: UUID, content: T) throws -> RegisterPayload {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(content)
            return RegisterPayload(queue: "whoswho", identifier: uuid, contentType: "application/json; charset=utf-8", bytes: Array(data))
        }

        private func send(payload: RegisterPayload, to root: BoxRuntimeOptions.RootServer, configuration: BoxConfiguration, configurationPath: String) async throws {
            let options = BoxRuntimeOptions(
                mode: .client,
                address: root.address,
                port: root.port,
                portOrigin: .configuration,
                addressOrigin: .configuration,
                configurationPath: configurationPath,
                adminChannelEnabled: false,
                logLevel: .info,
                logTarget: .stderr,
                logLevelOrigin: .default,
                logTargetOrigin: .default,
                nodeId: configuration.common.nodeUUID,
                userId: configuration.common.userUUID,
                portMappingRequested: false,
                clientAction: .put(queuePath: payload.queue, contentType: payload.contentType, data: payload.bytes),
                portMappingOrigin: .default
            )
            do {
                try await BoxClient.run(with: options)
            } catch let clientError as BoxClientError {
                throw ValidationError(describeRegisterFailure(for: payload, root: root, error: clientError))
            }
        }

        private func describeRegisterFailure(for payload: RegisterPayload, root: BoxRuntimeOptions.RootServer, error: BoxClientError) -> String {
            let target = "\(root.address):\(root.port)"
            switch error {
            case let .remoteRejected(status, message):
                let statusLabel = String(describing: status)
                return "Remote \(target) rejected registration payload for \(payload.identifier.uuidString) (\(statusLabel): \(message))"
            default:
                return "Registration client error against \(target): \(error.localizedDescription)"
            }
        }

        private func loadExistingUserNodes(configuration: BoxConfiguration) throws -> Set<UUID> {
            guard let queuesDirectory = BoxPaths.queuesDirectory() else {
                return []
            }
            let fileURL = queuesDirectory.appendingPathComponent("whoswho", isDirectory: true).appendingPathComponent("\(configuration.common.userUUID.uuidString.uppercased()).json", isDirectory: false)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return []
            }
            do {
                let data = try Data(contentsOf: fileURL)
                let userRecord = try JSONDecoder().decode(LocationServiceUserRecord.self, from: data)
                return Set(userRecord.nodeUUIDs)
            } catch {
                return []
            }
        }

        private func persistLocalUserRecord(configuration: BoxConfiguration, userRecord: LocationServiceUserRecord) throws {
            guard let queuesDirectory = BoxPaths.queuesDirectory() else {
                return
            }
            let directoryURL = queuesDirectory.appendingPathComponent("whoswho", isDirectory: true)
            let fileURL = directoryURL.appendingPathComponent("\(configuration.common.userUUID.uuidString.uppercased()).json", isDirectory: false)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(userRecord)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
#if !os(Windows)
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: fileURL.path)
#endif
        }

        private func hexString(_ bytes: [UInt8]) -> String {
            bytes.map { String(format: "%02x", $0) }.joined()
        }

        private struct RegisterPayload {
            var queue: String
            var identifier: UUID
            var contentType: String
            var bytes: [UInt8]
        }
    }

    /// Flag selecting server mode (`box --server`).
    @Flag(name: [.short, .long], help: "Run the Box daemon.")
    public var server: Bool = false

    /// Flag displaying version/build metadata and exiting.
    @Flag(name: [.short, .customLong("version")], help: "Show version information and exit.")
    public var version: Bool = false

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

    /// Opt-in flag enabling automatic port mapping (PCP/NAT-PMP/UPnP) for server mode.
    @Flag(name: .customLong("enable-port-mapping"), inversion: .prefixedNo, help: "Attempt automatic port mapping via PCP/NAT-PMP/UPnP (server mode).")
    public var enablePortMapping: Bool = false

    /// Manual external address advertised when automatic detection is unavailable (server mode only).
    @Option(name: .customLong("external-address"), help: "Manual external address advertised to peers (server mode).")
    public var externalAddressOverride: String?

    /// Manual external UDP port advertised together with `--external-address`.
    @Option(name: .customLong("external-port"), help: "External UDP port advertised with --external-address (defaults to the effective port).")
    public var externalPortOverride: UInt16?

    /// Default memberwise initializer required by swift-argument-parser.
    public init() {}

    /// Parses CLI arguments, configures logging, and dispatches to either the server or the client.
    public mutating func run() async throws {
        if version {
            let output = BoxVersionInfo.description + "\n"
            if let data = output.data(using: .utf8) {
                FileHandle.standardOutput.write(data)
            }
            return
        }

        let cliLogLevel = Logger.Level(logLevelString: logLevel)
        let cliLogTarget = try resolveLogTarget()
        let resolvedMode: BoxRuntimeMode = server ? .server : .client

        if externalPortOverride != nil, externalAddressOverride == nil {
            throw ValidationError("--external-port requires --external-address.")
        }

        if resolvedMode == .client {
            if externalAddressOverride != nil {
                throw ValidationError("--external-address is only available in server mode.")
            }
            if externalPortOverride != nil {
                throw ValidationError("--external-port is only available in server mode.")
            }
        }

        let configurationResult = try BoxConfiguration.loadDefault(explicitPath: configurationPath)
        let configuration = configurationResult?.configuration
        let clientConfiguration = configuration?.client
        let serverConfiguration = configuration?.server
        let commonConfiguration = configuration?.common

        let (effectiveLogLevel, logLevelOrigin): (Logger.Level, BoxRuntimeOptions.LogLevelOrigin) = {
            if logLevel != nil {
                return (cliLogLevel, .cliFlag)
            }
            let configLevel = (resolvedMode == .server) ? serverConfiguration?.logLevel : clientConfiguration?.logLevel
            if let configLevel {
                return (configLevel, .configuration)
            }
            return (.info, .default)
        }()

        let (effectiveLogTarget, logTargetOrigin): (BoxLogTarget, BoxRuntimeOptions.LogTargetOrigin) = {
            if let cliTarget = cliLogTarget {
                return (cliTarget, .cliFlag)
            }
            let configTargetString = (resolvedMode == .server) ? serverConfiguration?.logTarget : clientConfiguration?.logTarget
            if let configTarget = configTargetString,
               let parsed = BoxLogTarget.parse(configTarget) {
                return (parsed, .configuration)
            }
            return (BoxRuntimeOptions.defaultLogTarget(for: resolvedMode), .default)
        }()

        let effectiveNodeId = commonConfiguration?.nodeUUID ?? UUID()
        let effectiveUserId = commonConfiguration?.userUUID ?? UUID()

        BoxLogging.bootstrap(level: effectiveLogLevel, target: effectiveLogTarget)

        let (effectiveAddress, addressOrigin): (String, BoxRuntimeOptions.AddressOrigin) = {
            if let cliAddress = address {
                return (cliAddress, .cliFlag)
            }
            if resolvedMode == .client,
               let configAddress = clientConfiguration?.address,
               !configAddress.isEmpty {
                return (configAddress, .configuration)
            }
            let fallback = resolvedMode == .server ? BoxRuntimeOptions.defaultServerBindAddress : BoxRuntimeOptions.defaultClientAddress
            return (fallback, .default)
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

        let (manualExternalAddress, manualExternalPort, manualExternalOrigin): (String?, UInt16?, BoxRuntimeOptions.ExternalAddressOrigin) = {
            guard resolvedMode == .server else {
                return (nil, nil, .default)
            }
            if let cliAddressRaw = externalAddressOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !cliAddressRaw.isEmpty {
                let portValue = externalPortOverride ?? effectivePort
                return (cliAddressRaw, portValue, .cliFlag)
            }
            if let configAddressRaw = serverConfiguration?.externalAddress?.trimmingCharacters(in: .whitespacesAndNewlines),
               !configAddressRaw.isEmpty {
                let portValue = serverConfiguration?.externalPort ?? effectivePort
                return (configAddressRaw, portValue, .configuration)
            }
            return (nil, nil, .default)
        }()

        let (portMappingRequested, portMappingOrigin): (Bool, BoxRuntimeOptions.PortMappingOrigin) = {
            guard resolvedMode == .server else {
                return (false, .default)
            }
            if enablePortMapping {
                return (true, .cliFlag)
            }
            if let configValue = serverConfiguration?.portMappingEnabled {
                return (configValue, .configuration)
            }
            return (false, .default)
        }()

        var permanentQueues = Set<String>()
        if resolvedMode == .server, let configuredQueues = serverConfiguration?.permanentQueues {
            for queue in configuredQueues {
                do {
                    let normalized = try BoxServerStore.normalizeQueueName(queue)
                    permanentQueues.insert(normalized)
                } catch {
                    throw ValidationError("Invalid permanent queue name: \(queue)")
                }
            }
        }

        let runtimeOptions = BoxRuntimeOptions(
            mode: resolvedMode,
            address: effectiveAddress,
            port: effectivePort,
            portOrigin: portOrigin,
            addressOrigin: addressOrigin,
            configurationPath: configurationPath,
            adminChannelEnabled: adminChannel,
            logLevel: effectiveLogLevel,
            logTarget: effectiveLogTarget,
            logLevelOrigin: logLevelOrigin,
            logTargetOrigin: logTargetOrigin,
            nodeId: effectiveNodeId,
            userId: effectiveUserId,
            portMappingRequested: portMappingRequested,
            clientAction: resolveClientAction(for: resolvedMode),
            portMappingOrigin: portMappingOrigin,
            externalAddressOverride: manualExternalAddress,
            externalPortOverride: manualExternalPort,
            externalAddressOrigin: manualExternalOrigin,
            permanentQueues: permanentQueues,
            rootServers: commonConfiguration?.rootServers ?? []
        )

        switch resolvedMode {
        case .server:
            try await BoxServer.run(with: runtimeOptions)
        case .client:
            do {
                try await BoxClient.run(with: runtimeOptions)
            } catch let clientError as BoxClientError {
                throw ValidationError(describeClientFailure(error: clientError, options: runtimeOptions))
            }
        }
    }

    /// Converts CLI flags into a concrete client action.
    /// - Parameter mode: Current runtime mode.
    /// - Returns: Client action, defaults to `.handshake`.
    private func resolveClientAction(for mode: BoxRuntimeMode) -> BoxClientAction {
        return .handshake
    }

    private func describeClientFailure(error: BoxClientError, options: BoxRuntimeOptions) -> String {
        let target = "\(options.address):\(options.port)"
        switch error {
        case let .remoteRejected(status, message):
            let statusLabel = String(describing: status)
            return "Remote \(target) rejected \(clientActionSummary(options.clientAction)) (\(statusLabel): \(message))"
        default:
            return "Client error during \(clientActionSummary(options.clientAction)) against \(target): \(error.localizedDescription)"
        }
    }

    private func clientActionSummary(_ action: BoxClientAction) -> String {
        switch action {
        case .handshake:
            return "handshake"
        case let .put(queuePath, _, _):
            return "put to \(queuePath)"
        case let .get(queuePath):
            return "get from \(queuePath)"
        case let .locate(node):
            return "locate \(node.uuidString)"
        case .ping:
            return "ping"
        case let .sync(queuePath):
            return "sync from \(queuePath)"
        }
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

    /// `box ping-roots` — send a ping to configured root servers and display their version banners.
    public struct PingRoots: AsyncParsableCommand {
        public static var configuration: CommandConfiguration {
            CommandConfiguration(
                commandName: "ping-roots",
                abstract: "Ping configured root servers and display their build information."
            )
        }

        @Option(name: .shortAndLong, help: "Configuration PLIST path (defaults to ~/.box/Box.plist).")
        public var path: String?

        @Option(name: .customLong("root"), parsing: .unconditionalSingleValue, help: "Root server override (host[:port]). Can be repeated.")
        public var rootOverrides: [String] = []

        public init() {}

        public mutating func run() async throws {
            let configurationURL = try BoxCommandParser.resolveConfigurationURL(path: path)
            let configurationResult = try BoxConfiguration.load(from: configurationURL)
            let configuration = configurationResult.configuration

            let rootServers = try BoxCommandParser.resolveRootServers(configuration: configuration, overrides: rootOverrides)
            guard !rootServers.isEmpty else {
                throw ValidationError("No root servers configured. Use --root or add entries to Box.plist.")
            }

            BoxLogging.update(level: .error)

            var failures: [(String, Error)] = []

            for root in rootServers {
                let options = BoxRuntimeOptions(
                    mode: .client,
                    address: root.address,
                    port: root.port,
                    portOrigin: .configuration,
                    addressOrigin: .configuration,
                    configurationPath: configurationResult.url.path,
                    adminChannelEnabled: false,
                    logLevel: .error,
                    logTarget: .stderr,
                    logLevelOrigin: .default,
                    logTargetOrigin: .default,
                    nodeId: configuration.common.nodeUUID,
                    userId: configuration.common.userUUID,
                    portMappingRequested: false,
                    clientAction: .ping,
                    portMappingOrigin: .default,
                    rootServers: []
                )

                do {
                    let message = try await BoxClient.ping(with: options)
                    let line = "Ping \(root.address):\(root.port) -> \(message)\n"
                    FileHandle.standardOutput.write(line.data(using: .utf8) ?? Data())
                } catch {
                    failures.append(("\(root.address):\(root.port)", error))
                }
            }

            if !failures.isEmpty {
                let lines = failures.map { entry in "Failed to ping \(entry.0): \(entry.1)" }
                throw ValidationError(lines.joined(separator: "\n"))
            }
        }
    }

    /// `box put` — publish a message using natural-language syntax.
    public struct Put: AsyncParsableCommand {
        public static var configuration: CommandConfiguration {
            CommandConfiguration(
                commandName: "put",
                abstract: "Publish a message to a remote Box queue using natural-language syntax."
            )
        }

        @Option(name: .customLong("config"), help: "Configuration PLIST path (defaults to ~/.box/Box.plist).")
        public var configurationPath: String?

        @Option(name: .long, help: "Log level (trace, debug, info, warn, error).")
        public var logLevel: String?

        @Option(name: .long, help: "Log target (stderr|stdout|file:<path>).")
        public var logTarget: String?

        @Argument(parsing: .captureForPassthrough, help: "Natural command expression (e.g. 'from [::1] port 12000 at <uuid> queue INBOX \"Hello\" as text/plain').")
        public var expression: [String] = []

        public init() {}

        public mutating func run() async throws {
            guard !expression.isEmpty else {
                throw ValidationError("Missing arguments. Example: box put at <UUID> \"Hello, World\"")
            }

            var stream = NaturalLanguageTokenStream(tokens: expression)
            let binding = try stream.parseBindingSpecifier()
            try stream.expectKeyword("at")
            let targetToken = try stream.nextValue("Expected target after 'at'.")
            let target = try NaturalTarget(token: targetToken)

            var queueOverride: String?
            if stream.consumeKeyword("queue") {
                queueOverride = try stream.nextValue("Expected queue name after 'queue'.")
            }

            let message = try stream.nextValue("Expected message payload (remember to quote it).")

            var contentType = "text/plain"
            if stream.consumeKeyword("as") {
                contentType = try stream.nextValue("Expected MIME type after 'as'.")
            }

            if stream.hasRemaining {
                throw ValidationError("Unexpected arguments: \(stream.remainingDescription)")
            }

            let configurationURL = try BoxCommandParser.resolveConfigurationURL(path: configurationPath)
            let configurationResult = try BoxConfiguration.load(from: configurationURL)
            let configuration = configurationResult.configuration

            let (effectiveLogLevel, logLevelOrigin, effectiveLogTarget, logTargetOrigin) = try BoxCommandParser.resolveClientLogging(
                logLevelOption: logLevel,
                logTargetOption: logTarget,
                configuration: configuration
            )

            BoxLogging.bootstrap(level: effectiveLogLevel, target: effectiveLogTarget)

            let queueName = try BoxCommandParser.resolveQueueName(preferred: queueOverride, embedded: target.queueComponent)
            let queuePath = "/" + queueName
            let cache = try LocationCache()
            let endpoints = try BoxCommandParser.resolveEndpoints(
                for: target,
                cache: cache,
                portOverride: target.portOverride,
                fallbackHost: configuration.client.address,
                fallbackPort: configuration.client.address == nil ? nil : (configuration.client.port ?? BoxRuntimeOptions.defaultPort)
            )

            guard !endpoints.isEmpty else {
                throw ValidationError("No reachable endpoints found for \(target.debugDescription).")
            }

            let messageBytes = [UInt8](message.utf8)
            let permanentQueues = try BoxCommandParser.permanentQueueSet(for: configuration)

            var failures: [(Endpoint, Error)] = []
            for endpoint in endpoints {
                let options = BoxRuntimeOptions(
                    mode: .client,
                    address: endpoint.address,
                    port: endpoint.port,
                    portOrigin: .cliFlag,
                    addressOrigin: .cliFlag,
                    configurationPath: configurationResult.url.path,
                    adminChannelEnabled: false,
                    logLevel: effectiveLogLevel,
                    logTarget: effectiveLogTarget,
                    logLevelOrigin: logLevelOrigin,
                    logTargetOrigin: logTargetOrigin,
                    nodeId: configuration.common.nodeUUID,
                    userId: configuration.common.userUUID,
                    portMappingRequested: false,
                    clientAction: .put(queuePath: queuePath, contentType: contentType, data: messageBytes),
                    portMappingOrigin: .default,
                    externalAddressOverride: nil,
                    externalPortOverride: nil,
                    externalAddressOrigin: .default,
                    permanentQueues: permanentQueues,
                    rootServers: configuration.common.rootServers,
                    bindAddress: binding.address,
                    bindPort: binding.port
                )

                do {
                    try await BoxClient.run(with: options)
                } catch {
                    failures.append((endpoint, error))
                }
            }

            if !failures.isEmpty {
                let lines = failures.map { failure -> String in
                    let endpoint = failure.0
                    return "- \(endpoint.nodeUUID.uuidString) @ \(BoxCommandParser.formatEndpointAddress(endpoint.address)):\(endpoint.port): \(failure.1.localizedDescription)"
                }.joined(separator: "\n")
                throw ValidationError("Failed to deliver message:\n\(lines)")
            }
        }
    }

    /// `box get` — retrieve a message from a remote queue.
    public struct Get: AsyncParsableCommand {
        public static var configuration: CommandConfiguration {
            CommandConfiguration(
                commandName: "get",
                abstract: "Retrieve a message from a remote Box queue."
            )
        }

        @Option(name: .customLong("config"), help: "Configuration PLIST path (defaults to ~/.box/Box.plist).")
        public var configurationPath: String?

        @Option(name: .long, help: "Log level (trace, debug, info, warn, error).")
        public var logLevel: String?

        @Option(name: .long, help: "Log target (stderr|stdout|file:<path>).")
        public var logTarget: String?

        @Argument(parsing: .captureForPassthrough, help: "Natural command expression (e.g. 'from <uuid> queue INBOX').")
        public var expression: [String] = []

        public init() {}

        public mutating func run() async throws {
            guard !expression.isEmpty else {
                throw ValidationError("Missing arguments. Example: box get from <UUID>")
            }

            var stream = NaturalLanguageTokenStream(tokens: expression)
            guard stream.consumeKeyword("from") || stream.consumeKeyword("at") else {
                throw ValidationError("Expected 'from' or 'at' before the target.")
            }
            let targetToken = try stream.nextValue("Expected target after keyword.")
            let target = try NaturalTarget(token: targetToken)

            var queueOverride: String?
            if stream.consumeKeyword("queue") {
                queueOverride = try stream.nextValue("Expected queue name after 'queue'.")
            }

            if stream.hasRemaining {
                throw ValidationError("Unexpected arguments: \(stream.remainingDescription)")
            }

            let configurationURL = try BoxCommandParser.resolveConfigurationURL(path: configurationPath)
            let configurationResult = try BoxConfiguration.load(from: configurationURL)
            let configuration = configurationResult.configuration

            let (effectiveLogLevel, logLevelOrigin, effectiveLogTarget, logTargetOrigin) = try BoxCommandParser.resolveClientLogging(
                logLevelOption: logLevel,
                logTargetOption: logTarget,
                configuration: configuration
            )

            BoxLogging.bootstrap(level: effectiveLogLevel, target: effectiveLogTarget)

            let queueName = try BoxCommandParser.resolveQueueName(preferred: queueOverride, embedded: target.queueComponent)
            let queuePath = "/" + queueName
            let cache = try LocationCache()
            let endpoints = try BoxCommandParser.resolveEndpoints(
                for: target,
                cache: cache,
                portOverride: target.portOverride,
                fallbackHost: configuration.client.address,
                fallbackPort: configuration.client.address == nil ? nil : (configuration.client.port ?? BoxRuntimeOptions.defaultPort)
            )

            guard !endpoints.isEmpty else {
                throw ValidationError("No reachable endpoints found for \(target.debugDescription).")
            }

            let permanentQueues = try BoxCommandParser.permanentQueueSet(for: configuration)
            var failures: [(Endpoint, Error)] = []

            for endpoint in endpoints {
                let options = BoxRuntimeOptions(
                    mode: .client,
                    address: endpoint.address,
                    port: endpoint.port,
                    portOrigin: .cliFlag,
                    addressOrigin: .cliFlag,
                    configurationPath: configurationResult.url.path,
                    adminChannelEnabled: false,
                    logLevel: effectiveLogLevel,
                    logTarget: effectiveLogTarget,
                    logLevelOrigin: logLevelOrigin,
                    logTargetOrigin: logTargetOrigin,
                    nodeId: configuration.common.nodeUUID,
                    userId: configuration.common.userUUID,
                    portMappingRequested: false,
                    clientAction: .get(queuePath: queuePath),
                    portMappingOrigin: .default,
                    externalAddressOverride: nil,
                    externalPortOverride: nil,
                    externalAddressOrigin: .default,
                    permanentQueues: permanentQueues,
                    rootServers: configuration.common.rootServers
                )

                do {
                    try await BoxClient.run(with: options)
                    return
                } catch {
                    failures.append((endpoint, error))
                }
            }

            let lines = failures.map { failure -> String in
                let endpoint = failure.0
                return "- \(endpoint.nodeUUID.uuidString) @ \(BoxCommandParser.formatEndpointAddress(endpoint.address)):\(endpoint.port): \(failure.1.localizedDescription)"
            }.joined(separator: "\n")
            throw ValidationError("Failed to retrieve message:\n\(lines)")
        }
    }

    /// `box locate` — resolve a node UUID via the remote Location Service.
    public struct Locate: AsyncParsableCommand {
        public static var configuration: CommandConfiguration {
            CommandConfiguration(
                commandName: "locate",
                abstract: "Resolve a node UUID via the remote Location Service."
            )
        }

        @Argument(help: "Node UUID to locate.")
        public var identifier: String

        @Option(name: .customLong("config"), help: "Configuration PLIST path (defaults to ~/.box/Box.plist).")
        public var configurationPath: String?

        @Option(name: [.short, .long], help: "Override target UDP port.")
        public var port: UInt16?

        @Option(name: [.short, .long], help: "Override target address.")
        public var address: String?

        @Option(name: .long, help: "Log level (trace, debug, info, warn, error).")
        public var logLevel: String?

        @Option(name: .long, help: "Log target (stderr|stdout|file:<path>).")
        public var logTarget: String?

        public init() {}

        public mutating func run() async throws {
            guard let uuid = UUID(uuidString: identifier) else {
                throw ValidationError("'\(identifier)' is not a valid UUID.")
            }

            let configurationURL = try BoxCommandParser.resolveConfigurationURL(path: configurationPath)
            let configurationResult = try BoxConfiguration.load(from: configurationURL)
            let configuration = configurationResult.configuration

            let (effectiveLogLevel, logLevelOrigin, effectiveLogTarget, logTargetOrigin) = try BoxCommandParser.resolveClientLogging(
                logLevelOption: logLevel,
                logTargetOption: logTarget,
                configuration: configuration
            )

            BoxLogging.bootstrap(level: effectiveLogLevel, target: effectiveLogTarget)

            let resolvedAddress: String
            let addressOrigin: BoxRuntimeOptions.AddressOrigin
            if let address {
                resolvedAddress = address
                addressOrigin = .cliFlag
            } else if let configuredAddress = configuration.client.address {
                resolvedAddress = configuredAddress
                addressOrigin = .configuration
            } else {
                resolvedAddress = BoxRuntimeOptions.defaultClientAddress
                addressOrigin = .default
            }

            let resolvedPort: UInt16
            let portOrigin: BoxRuntimeOptions.PortOrigin
            if let port {
                resolvedPort = port
                portOrigin = .cliFlag
            } else if let configuredPort = configuration.client.port {
                resolvedPort = configuredPort
                portOrigin = .configuration
            } else {
                resolvedPort = BoxRuntimeOptions.defaultPort
                portOrigin = .default
            }

            let permanentQueues = try BoxCommandParser.permanentQueueSet(for: configuration)

            let options = BoxRuntimeOptions(
                mode: .client,
                address: resolvedAddress,
                port: resolvedPort,
                portOrigin: portOrigin,
                addressOrigin: addressOrigin,
                configurationPath: configurationResult.url.path,
                adminChannelEnabled: false,
                logLevel: effectiveLogLevel,
                logTarget: effectiveLogTarget,
                logLevelOrigin: logLevelOrigin,
                logTargetOrigin: logTargetOrigin,
                nodeId: configuration.common.nodeUUID,
                userId: configuration.common.userUUID,
                portMappingRequested: false,
                clientAction: .locate(node: uuid),
                portMappingOrigin: .default,
                externalAddressOverride: nil,
                externalPortOverride: nil,
                externalAddressOrigin: .default,
                permanentQueues: permanentQueues,
                rootServers: configuration.common.rootServers
            )

            do {
                try await BoxClient.run(with: options)
            } catch let clientError as BoxClientError {
                throw ValidationError("Locate failed: \(clientError.localizedDescription)")
            }
        }
    }
extension BoxCommandParser {
    static func resolveConfigurationURL(path: String?) throws -> URL {
        if let path, !path.isEmpty {
            return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        }
        guard let defaultURL = BoxPaths.configurationURL(explicitPath: nil) else {
            throw ValidationError("Unable to determine configuration path. Specify one with --path.")
        }
        return defaultURL
    }

    static func resolveRootServers(configuration: BoxConfiguration, overrides: [String]) throws -> [BoxRuntimeOptions.RootServer] {
        if overrides.isEmpty {
            return configuration.common.rootServers
        }
        return try overrides.map { try parseRootEndpoint($0) }
    }

    static func parseRootEndpoint(_ string: String) throws -> BoxRuntimeOptions.RootServer {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ValidationError("Root endpoint cannot be empty.")
        }
        let components = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        if components.count == 1 {
            return BoxRuntimeOptions.RootServer(address: String(components[0]), port: BoxRuntimeOptions.defaultPort)
        } else if components.count == 2, let port = UInt16(components[1]) {
            return BoxRuntimeOptions.RootServer(address: String(components[0]), port: port)
        }
        throw ValidationError("Invalid root endpoint format: \(string). Expected host[:port].")
    }

    /// Resolves the effective logging configuration for client-oriented subcommands.
    /// - Parameters:
    ///   - logLevelOption: CLI override for the log level.
    ///   - logTargetOption: CLI override for the log target.
    ///   - configuration: Resolved Box configuration.
    /// - Returns: Tuple containing the selected level/target and their origins.
    static func resolveClientLogging(
        logLevelOption: String?,
        logTargetOption: String?,
        configuration: BoxConfiguration
    ) throws -> (Logger.Level, BoxRuntimeOptions.LogLevelOrigin, BoxLogTarget, BoxRuntimeOptions.LogTargetOrigin) {
        let cliLevel = Logger.Level(logLevelString: logLevelOption)
        let (level, levelOrigin): (Logger.Level, BoxRuntimeOptions.LogLevelOrigin) = {
            if logLevelOption != nil {
                return (cliLevel, .cliFlag)
            }
            if let configurationLevel = configuration.client.logLevel {
                return (configurationLevel, .configuration)
            }
            return (.info, .default)
        }()

        if let rawTarget = logTargetOption, BoxLogTarget.parse(rawTarget) == nil {
            throw ValidationError("Invalid log target. Expected stderr|stdout|file:<path>.")
        }
        let (target, targetOrigin): (BoxLogTarget, BoxRuntimeOptions.LogTargetOrigin) = {
            if let rawTarget = logTargetOption, let parsed = BoxLogTarget.parse(rawTarget) {
                return (parsed, .cliFlag)
            }
            if let configTarget = configuration.client.logTarget,
               let parsed = BoxLogTarget.parse(configTarget) {
                return (parsed, .configuration)
            }
            return (BoxRuntimeOptions.defaultLogTarget(for: .client), .default)
        }()

        return (level, levelOrigin, target, targetOrigin)
    }

    /// Resolves the queue name based on explicit and embedded hints.
    /// - Parameters:
    ///   - preferred: Queue specified via the `queue` keyword.
    ///   - embedded: Queue discovered within a `box://` URL.
    /// - Returns: Normalised queue name.
    static func resolveQueueName(preferred: String?, embedded: String?) throws -> String {
        if let preferred, !preferred.isEmpty {
            return try BoxServerStore.normalizeQueueName(preferred)
        }
        if let embedded, !embedded.isEmpty {
            return try BoxServerStore.normalizeQueueName(embedded)
        }
        return "INBOX"
    }

    /// Returns the configured set of permanent queues.
    /// - Parameter configuration: Global configuration loaded from disk.
    /// - Returns: Normalised set of permanent queue names.
    static func permanentQueueSet(for configuration: BoxConfiguration) throws -> Set<String> {
        guard let values = configuration.server.permanentQueues, !values.isEmpty else {
            return []
        }
        var result = Set<String>()
        for queue in values {
            let normalized = try BoxServerStore.normalizeQueueName(queue)
            result.insert(normalized)
        }
        return result
    }

    /// Resolves the list of endpoints targeted by the supplied natural-language expression.
    /// - Parameters:
    ///   - target: Parsed natural target.
    ///   - cache: Location Service cache used to fetch node/user records.
    ///   - portOverride: Optional port override supplied by the CLI.
    ///   - fallbackHost: Fallback address sourced from the configuration.
    ///   - fallbackPort: Fallback port sourced from the configuration.
    /// - Returns: Sorted list of endpoints ready for client delivery.
    fileprivate static func resolveEndpoints(
        for target: NaturalTarget,
        cache: LocationCache,
        portOverride: UInt16?,
        fallbackHost: String?,
        fallbackPort: UInt16?
    ) throws -> [Endpoint] {
        switch target.kind {
        case .uuid(let identifier):
            if let record = try cache.nodeRecord(for: identifier) {
                try ensureNodeOnline(record)
                let endpoint = try makeEndpoint(
                    for: record,
                    portOverride: portOverride,
                    fallbackHost: fallbackHost,
                    fallbackPort: fallbackPort
                )
                return [endpoint]
            }
            if let userRecord = try cache.userRecord(for: identifier) {
                return try resolveUserEndpoints(
                    userRecord: userRecord,
                    cache: cache,
                    portOverride: portOverride,
                    fallbackHost: fallbackHost,
                    fallbackPort: fallbackPort
                )
            }
            if let fallbackHost {
                let resolvedPort = portOverride ?? fallbackPort ?? BoxRuntimeOptions.defaultPort
                return [Endpoint(nodeUUID: identifier, address: fallbackHost, port: resolvedPort)]
            }
            throw ValidationError("No Location Service entry found for \(identifier.uuidString).")

        case .boxURL(let spec):
            switch spec.nodeSpecifier {
            case .specific(let nodeUUID):
                guard let record = try cache.nodeRecord(for: nodeUUID) else {
                    if let fallbackHost {
                        let resolvedPort = portOverride
                            ?? spec.port
                            ?? fallbackPort
                            ?? BoxRuntimeOptions.defaultPort
                        return [Endpoint(nodeUUID: nodeUUID, address: fallbackHost, port: resolvedPort)]
                    }
                    throw ValidationError("No Location Service record found for node \(nodeUUID.uuidString).")
                }
                guard record.userUUID == spec.userUUID else {
                    throw ValidationError("Node \(nodeUUID.uuidString) does not belong to user \(spec.userUUID.uuidString).")
                }
                try ensureNodeOnline(record)
                let endpoint = try makeEndpoint(
                    for: record,
                    portOverride: portOverride ?? spec.port,
                    fallbackHost: fallbackHost,
                    fallbackPort: fallbackPort
                )
                return [endpoint]

            case .wildcard:
                guard let userRecord = try cache.userRecord(for: spec.userUUID) else {
                    throw ValidationError("No Location Service record found for user \(spec.userUUID.uuidString).")
                }
                return try resolveUserEndpoints(
                    userRecord: userRecord,
                    cache: cache,
                    portOverride: portOverride ?? spec.port,
                    fallbackHost: fallbackHost,
                    fallbackPort: fallbackPort
                )
            }
        }
    }

    /// Formats IP addresses in a display-friendly form (wraps IPv6 in brackets).
    /// - Parameter address: Address string to display.
    /// - Returns: Address suitable for CLI display.
    static func formatEndpointAddress(_ address: String) -> String {
        if address.contains(":"), !address.hasPrefix("["), !address.hasSuffix("]") {
            return "[\(address)]"
        }
        return address
    }

    /// Ensures the node record denotes an online node before attempting delivery.
    /// - Parameter record: Location Service node record.
    private static func ensureNodeOnline(_ record: LocationServiceNodeRecord) throws {
        if record.online == false {
            throw ValidationError("Node \(record.nodeUUID.uuidString) is currently offline.")
        }
    }

    /// Resolves endpoints for every online node owned by the supplied user record.
    private static func resolveUserEndpoints(
        userRecord: LocationServiceUserRecord,
        cache: LocationCache,
        portOverride: UInt16?,
        fallbackHost: String?,
        fallbackPort: UInt16?
    ) throws -> [Endpoint] {
        var endpoints: [Endpoint] = []
        endpoints.reserveCapacity(userRecord.nodeUUIDs.count)

        for nodeUUID in userRecord.nodeUUIDs {
            guard let record = try cache.nodeRecord(for: nodeUUID) else {
                continue
            }
            guard record.userUUID == userRecord.userUUID else {
                continue
            }
            guard record.online else {
                continue
            }
            let endpoint = try makeEndpoint(
                for: record,
                portOverride: portOverride,
                fallbackHost: fallbackHost,
                fallbackPort: fallbackPort
            )
            endpoints.append(endpoint)
        }

        guard !endpoints.isEmpty else {
            throw ValidationError("No online nodes available for user \(userRecord.userUUID.uuidString).")
        }

        return endpoints.sorted { lhs, rhs in
            lhs.nodeUUID.uuidString < rhs.nodeUUID.uuidString
        }
    }

    /// Selects the optimal address advertised by a node.
    private static func makeEndpoint(
        for record: LocationServiceNodeRecord,
        portOverride: UInt16?,
        fallbackHost: String?,
        fallbackPort: UInt16?
    ) throws -> Endpoint {
        var candidates: [AddressCandidate] = []
        candidates.reserveCapacity(record.addresses.count + 2)

        for address in record.addresses {
            let port = portOverride ?? address.port
            let candidate = AddressCandidate(
                ip: address.ip,
                port: port,
                scope: address.scope,
                source: address.source,
                origin: .record
            )
            candidates.append(candidate)
        }

        if let externalIPv4 = record.connectivity.portMapping.externalIPv4 {
            let inferredPort = portOverride
                ?? record.connectivity.portMapping.externalPort
                ?? record.addresses.first?.port
                ?? fallbackPort
                ?? BoxRuntimeOptions.defaultPort
            candidates.append(
                AddressCandidate(
                    ip: externalIPv4,
                    port: inferredPort,
                    scope: .global,
                    source: nil,
                    origin: .portMapping
                )
            )
        }

        if candidates.isEmpty, let fallbackHost {
            let inferredPort = portOverride
                ?? fallbackPort
                ?? record.addresses.first?.port
                ?? BoxRuntimeOptions.defaultPort
            candidates.append(
                AddressCandidate(
                    ip: fallbackHost,
                    port: inferredPort,
                    scope: nil,
                    source: nil,
                    origin: .fallback
                )
            )
        }

        guard let selected = selectPreferredAddress(from: candidates) else {
            throw ValidationError("Node \(record.nodeUUID.uuidString) does not advertise any reachable address.")
        }

        return Endpoint(nodeUUID: record.nodeUUID, address: selected.ip, port: selected.port)
    }

    /// Picks the best candidate from the provided list.
    private static func selectPreferredAddress(from candidates: [AddressCandidate]) -> AddressCandidate? {
        guard !candidates.isEmpty else { return nil }
        return candidates.sorted { lhs, rhs in
            let lhsScope = scopeRank(for: lhs)
            let rhsScope = scopeRank(for: rhs)
            if lhsScope != rhsScope {
                return lhsScope < rhsScope
            }

            let lhsFamily = ipFamilyRank(for: lhs.ip)
            let rhsFamily = ipFamilyRank(for: rhs.ip)
            if lhsFamily != rhsFamily {
                return lhsFamily < rhsFamily
            }

            let lhsSource = sourceRank(for: lhs)
            let rhsSource = sourceRank(for: rhs)
            if lhsSource != rhsSource {
                return lhsSource < rhsSource
            }

            if lhs.origin.rawValue != rhs.origin.rawValue {
                return lhs.origin.rawValue < rhs.origin.rawValue
            }

            if lhs.ip != rhs.ip {
                return lhs.ip < rhs.ip
            }
            return lhs.port < rhs.port
        }.first
    }

    /// Returns a ranking for the supplied candidate scope.
    private static func scopeRank(for candidate: AddressCandidate) -> Int {
        switch candidate.origin {
        case .fallback:
            return 3
        case .portMapping:
            return 0
        case .record:
            switch candidate.scope {
            case .some(.global):
                return 0
            case .some(.lan):
                return 1
            case .some(.loopback):
                return 2
            case .none:
                return 3
            }
        }
    }

    /// Returns a ranking used to prefer IPv6 addresses over IPv4.
    private static func ipFamilyRank(for address: String) -> Int {
        address.contains(":") ? 0 : 1
    }

    /// Returns a ranking for the Location Service source metadata.
    private static func sourceRank(for candidate: AddressCandidate) -> Int {
        if candidate.origin == .portMapping {
            return 0
        }
        switch candidate.source {
        case .some(.probe):
            return 0
        case .some(.manual):
            return 1
        case .some(.config):
            return 2
        case .none:
            return 3
        }
    }
}

// MARK: - Admin Subcommands

extension BoxCommandParser {
    /// `box init-config` — bootstrap or repair the configuration PLIST.
    public struct InitConfig: AsyncParsableCommand {
        public static var configuration: CommandConfiguration {
            CommandConfiguration(
                commandName: "init-config",
                abstract: "Create or repair ~/.box/Box.plist (ensures UUIDs and default sections)."
            )
        }

        @Option(name: .shortAndLong, help: "Configuration PLIST path (defaults to ~/.box/Box.plist).")
        public var path: String?

        @Flag(name: .long, help: "Regenerate node and user UUIDs even if they already exist.")
        public var rotateIdentities: Bool = false

        @Flag(name: .long, help: "Emit the summary as JSON.")
        public var json: Bool = false

        @Option(name: .customLong("user-uuid"), help: "Reuse an existing user UUID instead of generating a new one.")
        public var providedUserUUID: String?

        public init() {}

        public mutating func run() async throws {
            let resolvedURL: URL
            if let path, !path.isEmpty {
                resolvedURL = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            } else if let defaultURL = BoxPaths.configurationURL(explicitPath: nil) {
                resolvedURL = defaultURL
            } else {
                throw ValidationError("Unable to determine configuration path. Specify one with --path.")
            }

            let usesDefaultLocation = path == nil
            try Self.ensureBaseDirectories(for: resolvedURL, usesDefaultLocation: usesDefaultLocation)

            var loadResult = try BoxConfiguration.load(from: resolvedURL)
            var configuration = loadResult.configuration
            var rotated = false
            var userIdentityRotated = false
            var nodeIdentityRotated = false

            let userUUIDInput = try Self.resolveUserUUID(
                provided: providedUserUUID,
                wasCreated: loadResult.wasCreated,
                current: configuration.common.userUUID
            )

            if rotateIdentities {
                rotated = true
                userIdentityRotated = true
                nodeIdentityRotated = true
                configuration.rotateIdentities()
                configuration.common.userUUID = userUUIDInput ?? configuration.common.userUUID
                try configuration.save(to: loadResult.url)
                loadResult.configuration = configuration
            } else if loadResult.wasCreated {
                if let suppliedUser = userUUIDInput {
                    configuration.common.userUUID = suppliedUser
                    userIdentityRotated = true
                }
                let newNodeUUID = UUID()
                configuration.common.nodeUUID = newNodeUUID
                nodeIdentityRotated = true
                let merged = Array(Set(configuration.common.rootServers).union(Self.defaultRootServers))
                configuration.common.rootServers = merged
                try configuration.save(to: loadResult.url)
                loadResult.configuration = configuration
            }

            if !rotateIdentities && !loadResult.wasCreated {
                var mergeSet = Set(configuration.common.rootServers)
                mergeSet.formUnion(Self.defaultRootServers)
                if mergeSet != Set(configuration.common.rootServers) {
                    configuration.common.rootServers = Array(mergeSet)
                    try configuration.save(to: loadResult.url)
                    loadResult.configuration = configuration
                }
            }

            try await Self.initialiseIdentities(
                configuration: loadResult.configuration,
                rotateIdentities: rotateIdentities,
                configurationJustCreated: loadResult.wasCreated,
                userUUIDWasForced: userUUIDInput != nil,
                userIdentityRotated: &userIdentityRotated,
                nodeIdentityRotated: &nodeIdentityRotated
            )

            let summary: [String: Any] = [
                "path": loadResult.url.path,
                "created": loadResult.wasCreated,
                "rotated": rotated,
                "nodeUUID": configuration.common.nodeUUID.uuidString,
                "userUUID": configuration.common.userUUID.uuidString,
                "userIdentityRotated": userIdentityRotated,
                "nodeIdentityRotated": nodeIdentityRotated
            ]

            if json {
                let data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write("\n".data(using: .utf8)!)
            } else {
                let createdText = loadResult.wasCreated ? "yes" : "no"
                let rotatedText = rotated ? "yes" : "no"
                let lines = [
                    "Configuration path: \(loadResult.url.path)",
                    "Created: \(createdText)",
                    "Rotated identities: \(rotatedText)",
                    "Node UUID: \(configuration.common.nodeUUID.uuidString)",
                    "User UUID: \(configuration.common.userUUID.uuidString)",
                    "User identity rotated: \(userIdentityRotated ? "yes" : "no")",
                    "Node identity rotated: \(nodeIdentityRotated ? "yes" : "no")"
                ]
                FileHandle.standardOutput.write(lines.joined(separator: "\n").data(using: .utf8) ?? Data())
                FileHandle.standardOutput.write("\n".data(using: .utf8)!)
            }
        }

        private static func ensureBaseDirectories(for configurationURL: URL, usesDefaultLocation: Bool) throws {
            if usesDefaultLocation {
                guard let boxDirectory = BoxPaths.boxDirectory() else {
                    throw ValidationError("Unable to resolve ~/.box directory. Set HOME or specify --path.")
                }
                try ensureDirectory(boxDirectory)
                if let runDirectory = BoxPaths.runDirectory() {
                    try ensureDirectory(runDirectory)
                }
                if let logsDirectory = BoxPaths.logsDirectory() {
                    try ensureDirectory(logsDirectory)
                }
                if let queuesDirectory = BoxPaths.queuesDirectory() {
                    try ensureDirectory(queuesDirectory)
                    try ensureDirectory(queuesDirectory.appendingPathComponent("INBOX", isDirectory: true))
                    try ensureDirectory(queuesDirectory.appendingPathComponent("whoswho", isDirectory: true))
                }
            } else {
                try ensureDirectory(configurationURL.deletingLastPathComponent())
            }
        }

        private static func ensureDirectory(_ url: URL) throws {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                if !isDirectory.boolValue {
                    throw ValidationError("Expected directory at \(url.path).")
                }
                return
            }
#if !os(Windows)
            let attributes: [FileAttributeKey: Any]? = [.posixPermissions: NSNumber(value: Int16(0o700))]
#else
            let attributes: [FileAttributeKey: Any]? = nil
#endif
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: attributes)
        }

        private static var defaultRootServers: Set<BoxRuntimeOptions.RootServer> {
            [
                BoxRuntimeOptions.RootServer(address: "2001:41d0:305:2100::b712", port: BoxRuntimeOptions.defaultPort),
                BoxRuntimeOptions.RootServer(address: "2001:41d0:305:2100::b711", port: BoxRuntimeOptions.defaultPort)
            ]
        }

        private static func resolveUserUUID(provided: String?, wasCreated: Bool, current: UUID) throws -> UUID? {
            if let provided, !provided.isEmpty {
                guard let parsed = UUID(uuidString: provided) else {
                    throw ValidationError("--user-uuid expects a valid UUID string.")
                }
                return parsed
            }

            guard wasCreated, stdinIsTTY else {
                return nil
            }

            FileHandle.standardOutput.write("Re-use existing user UUID? Leave blank to generate a new one.\\nUser UUID: ".data(using: .utf8) ?? Data())
#if !os(Windows)
            fflush(nil)
#endif
            if let input = readLine(), !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let parsed = UUID(uuidString: trimmed) else {
                    throw ValidationError("Provided user UUID is not valid: \(trimmed)")
                }
                return parsed
            }
            return nil
        }

        private static func initialiseIdentities(
            configuration: BoxConfiguration,
            rotateIdentities: Bool,
            configurationJustCreated: Bool,
            userUUIDWasForced: Bool,
            userIdentityRotated: inout Bool,
            nodeIdentityRotated: inout Bool
        ) async throws {
            let keyStore = try BoxNoiseKeyStore()

            var userMaterial: BoxIdentityMaterial
            var nodeMaterial: BoxIdentityMaterial

            if rotateIdentities {
                userMaterial = try await keyStore.regenerateIdentity(for: .client)
                nodeMaterial = try await keyStore.regenerateIdentity(for: .node)
                userIdentityRotated = true
                nodeIdentityRotated = true
            } else {
                if configurationJustCreated {
                    if await keyStore.identityExists(for: .client) {
                        userMaterial = try await keyStore.loadIdentity(for: .client)
                    } else {
                        userMaterial = try await keyStore.regenerateIdentity(for: .client)
                        userIdentityRotated = true
                    }
                    nodeMaterial = try await keyStore.regenerateIdentity(for: .node)
                    nodeIdentityRotated = true
                } else {
                    userMaterial = try await keyStore.ensureIdentity(for: .client)
                    nodeMaterial = try await keyStore.ensureIdentity(for: .node)
                }
            }

            try await keyStore.persistLink(
                userUUID: configuration.common.userUUID,
                nodeUUID: configuration.common.nodeUUID,
                userMaterial: userMaterial,
                nodeMaterial: nodeMaterial
            )
        }

        private static var stdinIsTTY: Bool {
#if os(Windows)
            return _isatty(_fileno(stdin)) != 0
#else
            return isatty(STDIN_FILENO) == 1
#endif
        }
    }

    /// `box admin` namespace handling administrative commands.
    public struct Admin: AsyncParsableCommand {
        public static var configuration: CommandConfiguration {
            CommandConfiguration(
                commandName: "admin",
                abstract: "Interact with the local admin channel.",
                subcommands: [Status.self, Ping.self, LogTarget.self, ReloadConfig.self, Stats.self, NatProbe.self, Locate.self, LocationSummary.self, SyncRoots.self]
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

        /// `box admin nat-probe` — attempts port mapping through available backends (UPnP/PCP/NAT-PMP).
        public struct NatProbe: AsyncParsableCommand {
            @Option(name: .shortAndLong, help: "Admin socket path (defaults to ~/.box/run/boxd.socket).")
            public var socket: String?

            @Option(name: .shortAndLong, help: "Override gateway address (defaults to the system gateway).")
            public var gateway: String?

            public init() {}

            public mutating func run() throws {
                var command = "nat-probe"
                if let gateway, !gateway.isEmpty {
                    let payload = try Admin.encodeJSON(["gateway": gateway])
                    command += " \(payload)"
                }
                let response = try Admin.sendCommand(command, socketOverride: socket)
                Admin.writeResponse(response)
            }
        }

        /// `box admin locate <uuid>` — resolves a node or user through the Location Service snapshot.
        public struct Locate: AsyncParsableCommand {
            @Option(name: .shortAndLong, help: "Admin socket path (defaults to ~/.box/run/boxd.socket).")
            public var socket: String?

            @Argument(help: "Node or user UUID to resolve.")
            public var target: String

            public init() {}

            public mutating func run() throws {
                guard UUID(uuidString: target) != nil else {
                    throw ValidationError("locate expects a valid UUID.")
                }
                let response = try Admin.sendCommand("locate \(target)", socketOverride: socket)
                Admin.writeResponse(response)
            }
        }

        /// `box admin location-summary` — renders the Location Service supervision snapshot.
        public struct LocationSummary: AsyncParsableCommand {
            @Option(name: .shortAndLong, help: "Admin socket path (defaults to ~/.box/run/boxd.socket).")
            public var socket: String?

            @Flag(name: .long, help: "Emit the summary as JSON instead of human-readable text.")
            public var json: Bool = false

            @Flag(name: .long, help: "Emit Prometheus exposition metrics instead of human-readable text.")
            public var prometheus: Bool = false

            @Flag(name: .long, help: "Exit with code 2 when stale nodes or users are detected.")
            public var failOnStale: Bool = false

            @Flag(name: .long, help: "Exit with code 3 when no nodes are registered.")
            public var failIfEmpty: Bool = false

            public init() {}

            public mutating func run() throws {
                if json && prometheus {
                    throw ValidationError("--json and --prometheus are mutually exclusive.")
                }

                let summary: [String: Any]
                let primaryResponse = try Admin.sendCommand("location-summary", socketOverride: socket)
                switch Admin.parseLocationSummaryResponse(primaryResponse) {
                case .summary(let payload):
                    summary = payload
                case .unknownCommand, .unsupported:
                    let fallback = try Admin.sendCommand("status", socketOverride: socket)
                    summary = try Admin.extractLocationSummary(fromStatus: fallback)
                case .error(let message):
                    throw ValidationError("location-summary failed: \(message)")
                }

                if prometheus {
                    let rendered = try Admin.formatPrometheusLocationSummary(summary)
                    FileHandle.standardOutput.write(rendered.data(using: .utf8) ?? Data())
                } else if json {
                    let data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
                    FileHandle.standardOutput.write(data)
                    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
                } else {
                    let rendered = Admin.formatLocationSummary(summary)
                    FileHandle.standardOutput.write(rendered.data(using: .utf8) ?? Data())
                }

                let totalNodes = summary["totalNodes"] as? Int ?? 0
                let staleNodes = summary["staleNodes"] as? [Any] ?? []
                let staleUsers = summary["staleUsers"] as? [Any] ?? []

                if failOnStale && (!staleNodes.isEmpty || !staleUsers.isEmpty) {
                    throw ExitCode(2)
                }
                if failIfEmpty && totalNodes == 0 {
                    throw ExitCode(3)
                }
            }
        }

        /// `box admin sync-roots` — publish all local Location Service records to configured roots.
        public struct SyncRoots: AsyncParsableCommand {
            @Option(name: .shortAndLong, help: "Admin socket path (defaults to ~/.box/run/boxd.socket).")
            public var socket: String?

            public init() {}

            public mutating func run() throws {
                let response = try Admin.sendCommand("sync-roots", socketOverride: socket)
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

        private static func extractLocationSummary(fromStatus response: String) throws -> [String: Any] {
            guard let data = response.data(using: .utf8) else {
                throw ValidationError("Unable to decode status response.")
            }
            let object = try JSONSerialization.jsonObject(with: data, options: [])
            guard let root = object as? [String: Any] else {
                throw ValidationError("Status response is not a JSON object.")
            }
            guard let summary = root["locationService"] as? [String: Any] else {
                throw ValidationError("Status response does not include locationService summary.")
            }
            return summary
        }

        private static func parseLocationSummaryResponse(_ response: String) -> LocationSummaryResult {
            guard let data = response.data(using: .utf8) else {
                return .unsupported
            }
            guard
                let object = try? JSONSerialization.jsonObject(with: data, options: []),
                let dictionary = object as? [String: Any],
                let status = dictionary["status"] as? String
            else {
                return .unsupported
            }
            if status == "ok" {
                guard let summary = dictionary["summary"] as? [String: Any] else {
                    return .unsupported
                }
                return .summary(summary)
            }
            let message = dictionary["message"] as? String ?? "unknown-error"
            if status == "error", message == "unknown-command" {
                return .unknownCommand
            }
            return .error(message)
        }

        private enum LocationSummaryResult {
            case summary([String: Any])
            case unknownCommand
            case error(String)
            case unsupported
        }

        private static func formatLocationSummary(_ summary: [String: Any]) -> String {
            let generatedAt = summary["generatedAt"] as? String ?? "unknown"
            let totalNodes = summary["totalNodes"] as? Int ?? 0
            let activeNodes = summary["activeNodes"] as? Int ?? 0
            let totalUsers = summary["totalUsers"] as? Int ?? 0
            let staleThreshold = summary["staleThresholdSeconds"] as? Int ?? 120
            let staleNodes = (summary["staleNodes"] as? [String]) ?? []
            let staleUsers = (summary["staleUsers"] as? [String]) ?? []

            let lines = [
                "Location Service Summary",
                "  generatedAt: \(generatedAt)",
                "  totalNodes: \(totalNodes)",
                "  activeNodes: \(activeNodes)",
                "  totalUsers: \(totalUsers)",
                "  staleThresholdSeconds: \(staleThreshold)",
                "  staleNodes: \(formatList(staleNodes))",
                "  staleUsers: \(formatList(staleUsers))"
            ]
            return lines.joined(separator: "\n") + "\n"
        }

        private static func formatPrometheusLocationSummary(_ summary: [String: Any]) throws -> String {
            let generatedAtString = summary["generatedAt"] as? String
            let totalNodes = summary["totalNodes"] as? Int ?? 0
            let activeNodes = summary["activeNodes"] as? Int ?? 0
            let totalUsers = summary["totalUsers"] as? Int ?? 0
            let staleNodes = (summary["staleNodes"] as? [String]) ?? []
            let staleUsers = (summary["staleUsers"] as? [String]) ?? []
            let threshold = summary["staleThresholdSeconds"] as? Int ?? 0

            var lines: [String] = [
                "# HELP box_location_nodes_total Total nodes registered in the embedded Location Service.",
                "# TYPE box_location_nodes_total gauge",
                "box_location_nodes_total \(totalNodes)",
                "# HELP box_location_nodes_active Nodes considered active within the staleness threshold.",
                "# TYPE box_location_nodes_active gauge",
                "box_location_nodes_active \(activeNodes)",
                "# HELP box_location_users_total Users currently present in the embedded Location Service.",
                "# TYPE box_location_users_total gauge",
                "box_location_users_total \(totalUsers)",
                "# HELP box_location_nodes_stale_total Nodes whose last heartbeat exceeded the staleness threshold.",
                "# TYPE box_location_nodes_stale_total gauge",
                "box_location_nodes_stale_total \(staleNodes.count)",
                "# HELP box_location_users_stale_total Users without any active node within the staleness threshold.",
                "# TYPE box_location_users_stale_total gauge",
                "box_location_users_stale_total \(staleUsers.count)",
                "# HELP box_location_stale_threshold_seconds Staleness threshold used to classify inactive records.",
                "# TYPE box_location_stale_threshold_seconds gauge",
                "box_location_stale_threshold_seconds \(threshold)"
            ]

            if let generatedAtString, let timestamp = Admin.prometheusTimestamp(from: generatedAtString) {
                lines.append("# HELP box_location_summary_generated_timestamp_seconds ISO 8601 generation time of the summary.")
                lines.append("# TYPE box_location_summary_generated_timestamp_seconds gauge")
                lines.append("box_location_summary_generated_timestamp_seconds \(timestamp)")
            }

            if !staleNodes.isEmpty {
                lines.append("# HELP box_location_stale_node_indicator Indicator metric for each stale node UUID (value=1).")
                lines.append("# TYPE box_location_stale_node_indicator gauge")
                for uuid in staleNodes {
                    let escaped = Admin.prometheusEscape(uuid)
                    lines.append("box_location_stale_node_indicator{node_uuid=\"\(escaped)\"} 1")
                }
            }

            if !staleUsers.isEmpty {
                lines.append("# HELP box_location_stale_user_indicator Indicator metric for each stale user UUID (value=1).")
                lines.append("# TYPE box_location_stale_user_indicator gauge")
                for uuid in staleUsers {
                    let escaped = Admin.prometheusEscape(uuid)
                    lines.append("box_location_stale_user_indicator{user_uuid=\"\(escaped)\"} 1")
                }
            }

            lines.append("")
            return lines.joined(separator: "\n")
        }

        private static func prometheusEscape(_ value: String) -> String {
            var escaped = ""
            for scalar in value.unicodeScalars {
                switch scalar {
                case "\"":
                    escaped.append("\\\"")
                case "\\":
                    escaped.append("\\\\")
                case "\n":
                    escaped.append("\\n")
                default:
                    escaped.unicodeScalars.append(scalar)
                }
            }
            return escaped
        }

        private static func prometheusTimestamp(from isoString: String) -> String? {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: isoString) {
                return String(format: "%.3f", date.timeIntervalSince1970)
            }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: isoString) {
                return String(format: "%.3f", date.timeIntervalSince1970)
            }
            return nil
        }

        private static func formatList(_ values: [String]) -> String {
            guard !values.isEmpty else { return "none" }
            return values.joined(separator: ", ")
        }
    }
}
