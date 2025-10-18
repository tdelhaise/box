import Dispatch
import Foundation
import Logging
import Puppy

/// Enumerates the supported logging targets for the Box runtime.
public enum BoxLogTarget: Equatable, Sendable {
    case stderr
    case stdout
    case file(String)

    public static func parse(_ value: String) -> BoxLogTarget? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.caseInsensitiveCompare("stderr") == .orderedSame {
            return .stderr
        }
        if trimmed.caseInsensitiveCompare("stdout") == .orderedSame {
            return .stdout
        }
        if trimmed.lowercased().hasPrefix("file:") {
            let pathStartIndex = trimmed.index(trimmed.startIndex, offsetBy: 5)
            let rawPath = trimmed[pathStartIndex...].trimmingCharacters(in: .whitespaces)
            guard !rawPath.isEmpty else { return nil }
            return .file(rawPath)
        }
        return nil
    }
}

/// Centralises Puppy logging bootstrap/update logic for the Box runtime.
public enum BoxLogging {
    public static func bootstrap(level: Logger.Level, target: BoxLogTarget) {
        BoxLoggingState.shared.bootstrap(level: level, target: target)
    }

    public static func update(level: Logger.Level) {
        BoxLoggingState.shared.updateLevel(level)
    }

    public static func update(target: BoxLogTarget) {
        BoxLoggingState.shared.updateTarget(target)
    }

    public static func currentTarget() -> BoxLogTarget {
        BoxLoggingState.shared.currentTargetValue()
    }
}

/// Internal shared state used to manage the Puppy backend.
private final class BoxLoggingState: @unchecked Sendable {
    static let shared = BoxLoggingState()

    private let lock = NSLock()
    private var puppy = Puppy()
    private var bootstrapped = false
    private var currentTarget: BoxLogTarget = .stderr
    private var currentLevel: Logger.Level = .info

    func bootstrap(level: Logger.Level, target: BoxLogTarget) {
        lock.lock()
        defer { lock.unlock() }
        currentLevel = level
        if !bootstrapped {
            currentTarget = target
            configureDestinations(for: target)
            LoggingSystem.bootstrap { [weak self] label in
                guard let self else {
                    return StreamLogHandler.standardError(label: label)
                }
                var handler = PuppyLogHandler(label: label, puppy: self.puppy)
                handler.logLevel = self.currentLevel
                return handler
            }
            bootstrapped = true
        } else {
            updateTargetLocked(target)
        }
    }

    func updateTarget(_ target: BoxLogTarget) {
        lock.lock()
        defer { lock.unlock() }
        guard bootstrapped else {
            currentTarget = target
            return
        }
        updateTargetLocked(target)
    }

    func updateLevel(_ level: Logger.Level) {
        lock.lock()
        defer { lock.unlock() }
        currentLevel = level
    }

    private func updateTargetLocked(_ target: BoxLogTarget) {
        guard target != currentTarget else { return }
        currentTarget = target
        configureDestinations(for: target)
    }

    func currentTargetValue() -> BoxLogTarget {
        lock.lock()
        defer { lock.unlock() }
        return currentTarget
    }

    private func configureDestinations(for target: BoxLogTarget) {
        puppy.removeAll()
        let formatter = BoxLogFormatter()
        switch target {
        case .stderr:
            let logger = StandardErrorLogger(format: formatter)
            puppy.add(logger)
        case .stdout:
            let logger = ConsoleLogger("box.stdout", logFormat: formatter)
            puppy.add(logger)
        case .file(let path):
            let expanded = NSString(string: path).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            let directoryURL = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            if let fileLogger = try? FileLogger("box.file", logFormat: formatter, fileURL: url) {
                puppy.add(fileLogger)
            } else {
                let fallback = StandardErrorLogger(format: formatter)
                puppy.add(fallback)
            }
        }
    }

    private struct StandardErrorLogger: Loggerable, Sendable {
        let label: String = "box.stderr"
        let queue = DispatchQueue(label: "box.stderr")
        let logLevel: LogLevel = .trace
        let logFormat: LogFormattable?

        init(format: LogFormattable) {
            self.logFormat = format
        }

        func log(_ level: LogLevel, string: String) {
            if let data = (string + "\n").data(using: .utf8) {
                FileHandle.standardError.write(data)
            }
        }
    }
}

/// Formats log records emitted through Puppy with rich contextual details.
private struct BoxLogFormatter: LogFormattable, Sendable {
    private static let formatterLock = NSLock()
    private static let timestampFormatter = TimestampFormatter()

    func formatMessage(
        _ level: LogLevel,
        message: String,
        tag: String,
        function: String,
        file: String,
        line: UInt,
        swiftLogInfo: [String: String],
        label: String,
        date: Date,
        threadID: UInt64
    ) -> String {
        let timestamp = Self.formatTimestamp(date)
        let levelComponent = level.description
        let category = swiftLogInfo["label"].flatMap { $0.isEmpty ? nil : $0 } ?? label
        let source = swiftLogInfo["source"].flatMap { $0.isEmpty ? nil : $0 }
        let metadata = swiftLogInfo["metadata"].flatMap { $0.isEmpty ? nil : $0 }

        var contextSegments: [String] = []
        contextSegments.append(fileContext(file: file, line: line))
        if !function.isEmpty {
            contextSegments.append(function)
        }
        if let source, source != "swiftlog" {
            contextSegments.append("source=\(source)")
        }
        contextSegments.append("thread=\(threadID)")
        if let metadata {
            contextSegments.append("metadata=\(metadata)")
        }

        let context = contextSegments.joined(separator: " ")
        return [timestamp, levelComponent, category, context, message]
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
    }

    private static func formatTimestamp(_ date: Date) -> String {
        formatterLock.lock()
        defer { formatterLock.unlock() }
        return timestampFormatter.string(from: date)
    }

    private func fileContext(file: String, line: UInt) -> String {
        "\(file):\(line)"
    }

    /// Thread-safe ISO 8601 formatter wrapper.
    private final class TimestampFormatter: @unchecked Sendable {
        private let formatter: ISO8601DateFormatter

        init() {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            self.formatter = formatter
        }

        func string(from date: Date) -> String {
            formatter.string(from: date)
        }
    }
}
