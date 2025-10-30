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
            subcommands: [Admin.self, InitConfig.self]
        )
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

    /// Optional PUT action described as `<queue>[:content-type]`.
    @Option(name: .customLong("put"), help: "PUT queue path (format: /queue[:content-type]).")
    public var putDescriptor: String?

    /// Optional GET queue path.
    @Option(name: .customLong("get"), help: "GET queue path.")
    public var getQueue: String?

    /// Optional Locate target node UUID.
    @Option(name: .customLong("locate"), help: "Locate a node UUID via the remote Location Service.")
    public var locateNode: String?

    /// Optional inline payload used for PUT.
    @Option(name: .customLong("data"), help: "Inline data used with --put (UTF-8).")
    public var dataString: String?

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
            let output = BoxBuildInfo.description + "\n"
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

        if resolvedMode == .server, locateNode != nil {
            throw ValidationError("--locate is only available in client mode.")
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
            clientAction: try resolveClientAction(for: resolvedMode),
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

        if locateNode != nil && (putDescriptor != nil || getQueue != nil) {
            throw ValidationError("Cannot combine --locate with --put or --get.")
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

        if let locateNode {
            guard let uuid = UUID(uuidString: locateNode) else {
                throw ValidationError("--locate expects a valid UUID.")
            }
            return .locate(node: uuid)
        }

        return .handshake
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

        public init() {}

        public mutating func run() throws {
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

            if rotateIdentities {
                rotated = true
                configuration.rotateIdentities()
                try configuration.save(to: loadResult.url)
                loadResult.configuration = configuration
            }

            let summary: [String: Any] = [
                "path": loadResult.url.path,
                "created": loadResult.wasCreated,
                "rotated": rotated,
                "nodeUUID": configuration.common.nodeUUID.uuidString,
                "userUUID": configuration.common.userUUID.uuidString
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
                    "User UUID: \(configuration.common.userUUID.uuidString)"
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
    }

    /// `box admin` namespace handling administrative commands.
    public struct Admin: AsyncParsableCommand {
        public static var configuration: CommandConfiguration {
            CommandConfiguration(
                commandName: "admin",
                abstract: "Interact with the local admin channel.",
                subcommands: [Status.self, Ping.self, LogTarget.self, ReloadConfig.self, Stats.self, NatProbe.self, Locate.self, LocationSummary.self]
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

            @Flag(name: .long, help: "Exit with code 2 when stale nodes or users are detected.")
            public var failOnStale: Bool = false

            @Flag(name: .long, help: "Exit with code 3 when no nodes are registered.")
            public var failIfEmpty: Bool = false

            public init() {}

            public mutating func run() throws {
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

                if json {
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

        private static func formatList(_ values: [String]) -> String {
            guard !values.isEmpty else { return "none" }
            return values.joined(separator: ", ")
        }
    }
}
