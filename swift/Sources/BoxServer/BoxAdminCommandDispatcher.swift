import Foundation

struct BoxAdminCommandDispatcher: Sendable {
    private let statusProvider: @Sendable () async -> String
    private let logTargetUpdater: @Sendable (String) async -> String
    private let reloadConfiguration: @Sendable (String?) async -> String
    private let statsProvider: @Sendable () async -> String
    private let locateNode: @Sendable (UUID) async -> String
    private let natProbe: @Sendable (String?) async -> String
    private let locationSummaryProvider: @Sendable () async -> String

    init(
        statusProvider: @escaping @Sendable () async -> String,
        logTargetUpdater: @escaping @Sendable (String) async -> String,
        reloadConfiguration: @escaping @Sendable (String?) async -> String,
        statsProvider: @escaping @Sendable () async -> String,
        locateNode: @escaping @Sendable (UUID) async -> String,
        natProbe: @escaping @Sendable (String?) async -> String,
        locationSummaryProvider: @escaping @Sendable () async -> String
    ) {
        self.statusProvider = statusProvider
        self.logTargetUpdater = logTargetUpdater
        self.reloadConfiguration = reloadConfiguration
        self.statsProvider = statsProvider
        self.locateNode = locateNode
        self.natProbe = natProbe
        self.locationSummaryProvider = locationSummaryProvider
    }

    func process(_ rawValue: String) async -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return adminResponse(["status": "error", "message": "empty-command"])
        }
        let command = parse(trimmed)
        switch command {
        case .status:
            return await statusProvider()
        case .ping:
            return adminResponse(["status": "ok", "message": "pong"])
        case .logTarget(let target):
            return await logTargetUpdater(target)
        case .reloadConfig(let path):
            return await reloadConfiguration(path)
        case .stats:
            return await statsProvider()
        case .locate(let node):
            return await locateNode(node)
        case .natProbe(let gateway):
            return await natProbe(gateway)
        case .locationSummary:
            return await locationSummaryProvider()
        case .invalid(let message):
            return adminResponse(["status": "error", "message": message])
        case .unknown(let value):
            return adminResponse(["status": "error", "message": "unknown-command", "command": value])
        }
    }

    private func parse(_ command: String) -> BoxAdminParsedCommand {
        if command == "status" {
            return .status
        }
        if command == "ping" {
            return .ping
        }
        if command.hasPrefix("log-target") {
            let remainder = command.dropFirst("log-target".count).trimmingCharacters(in: .whitespaces)
            if remainder.isEmpty {
                return .invalid("missing-log-target")
            }
            if remainder.hasPrefix("{") {
                guard let target = extractStringField(from: String(remainder), field: "target") else {
                    return .invalid("invalid-log-target-payload")
                }
                return .logTarget(target)
            }
            return .logTarget(String(remainder))
        }
        if command.hasPrefix("reload-config") {
            let remainder = command.dropFirst("reload-config".count).trimmingCharacters(in: .whitespaces)
            if remainder.isEmpty {
                return .reloadConfig(nil)
            }
            if remainder.hasPrefix("{") {
                guard let path = extractStringField(from: String(remainder), field: "path") else {
                    return .invalid("invalid-reload-config-payload")
                }
                return .reloadConfig(path)
            }
            return .reloadConfig(String(remainder))
        }
        if command == "stats" {
            return .stats
        }
        if command.hasPrefix("nat-probe") {
            let remainder = command.dropFirst("nat-probe".count).trimmingCharacters(in: .whitespaces)
            if remainder.isEmpty {
                return .natProbe(nil)
            }
            if remainder.hasPrefix("{") {
                let gateway = extractStringField(from: String(remainder), field: "gateway")
                return .natProbe(gateway)
            }
            return .natProbe(String(remainder))
        }
        if command.hasPrefix("locate") {
            let remainder = command.dropFirst("locate".count).trimmingCharacters(in: .whitespaces)
            guard !remainder.isEmpty else {
                return .invalid("missing-locate-target")
            }
            if remainder.hasPrefix("{") {
                guard let nodeString = extractStringField(from: String(remainder), field: "node"),
                      let uuid = UUID(uuidString: nodeString) else {
                    return .invalid("invalid-locate-payload")
                }
                return .locate(uuid)
            }
            guard let uuid = UUID(uuidString: remainder) else {
                return .invalid("invalid-node-uuid")
            }
            return .locate(uuid)
        }
        if command == "location-summary" {
            return .locationSummary
        }
        return .unknown(command)
    }

    private func extractStringField(from jsonString: String, field: String) -> String? {
        guard let data = jsonString.data(using: .utf8) else {
            return nil
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: data, options: []),
            let dictionary = object as? [String: Any],
            let value = dictionary[field] as? String,
            !value.isEmpty
        else {
            return nil
        }
        return value
    }
}
