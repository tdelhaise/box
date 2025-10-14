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

    public static func update(target: BoxLogTarget) {
        BoxLoggingState.shared.updateTarget(target)
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

    private func updateTargetLocked(_ target: BoxLogTarget) {
        guard target != currentTarget else { return }
        currentTarget = target
        configureDestinations(for: target)
    }

    private func configureDestinations(for target: BoxLogTarget) {
        puppy.removeAll()
        switch target {
        case .stderr:
            let logger = StandardErrorLogger()
            puppy.add(logger)
        case .stdout:
            let logger = ConsoleLogger("box.stdout")
            puppy.add(logger)
        case .file(let path):
            let expanded = NSString(string: path).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            let directoryURL = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            if let fileLogger = try? FileLogger("box.file", fileURL: url) {
                puppy.add(fileLogger)
            } else {
                let fallback = StandardErrorLogger()
                puppy.add(fallback)
            }
        }
    }

    private struct StandardErrorLogger: Loggerable, Sendable {
        let label = "box.stderr"
        let queue = DispatchQueue(label: "box.stderr")
        let logLevel: LogLevel = .trace
        let logFormat: LogFormattable? = nil

        func log(_ level: LogLevel, string: String) {
            if let data = (string + "\n").data(using: .utf8) {
                FileHandle.standardError.write(data)
            }
        }
    }
}
