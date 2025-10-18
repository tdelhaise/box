import Foundation

/// Collection of helper functions returning well-known paths used by Box.
public enum BoxPaths {
    /// Resolves the current user's home directory.
    /// - Returns: URL pointing to the home directory when discoverable.
    public static func homeDirectory() -> URL? {
        if let pointer = getenv("HOME"), pointer.pointee != 0 {
            let home = String(cString: pointer)
            if !home.isEmpty {
                return URL(fileURLWithPath: home, isDirectory: true)
            }
        } else if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        return FileManager.default.homeDirectoryForCurrentUser
#else
        return nil
        #endif
    }

    /// Computes the Box root directory (`~/.box`).
    /// - Returns: URL of the Box directory when the home directory exists.
    public static func boxDirectory() -> URL? {
        homeDirectory()?.appendingPathComponent(".box", isDirectory: true)
    }

    /// Computes the Box run directory (`~/.box/run`).
    /// - Returns: URL of the run directory when the home directory exists.
    public static func runDirectory() -> URL? {
        boxDirectory()?.appendingPathComponent("run", isDirectory: true)
    }

    /// Resolves the shared configuration path (`~/.box/Box.plist`), using an explicit CLI path when provided.
    /// - Parameter explicitPath: Optional path passed by the user.
    /// - Returns: URL to the configuration file or `nil` when it cannot be determined.
    public static func configurationURL(explicitPath: String?) -> URL? {
        if let explicitPath, !explicitPath.isEmpty {
            return URL(fileURLWithPath: NSString(string: explicitPath).expandingTildeInPath)
        }
        return boxDirectory()?.appendingPathComponent("Box.plist", isDirectory: false)
    }

    /// Resolves the server configuration path, using an explicit CLI path when provided.
    /// - Parameter explicitPath: Optional path passed by the user.
    /// - Returns: URL to the configuration file or `nil` when it cannot be determined.
    public static func serverConfigurationURL(explicitPath: String?) -> URL? {
        configurationURL(explicitPath: explicitPath)
    }

    /// Resolves the client configuration path, using an explicit CLI path when provided.
    /// - Parameter explicitPath: Optional path passed by the user.
    /// - Returns: URL to the configuration file or `nil` when it cannot be determined.
    public static func clientConfigurationURL(explicitPath: String?) -> URL? {
        configurationURL(explicitPath: explicitPath)
    }

    /// Resolves the root directory storing queue data (`~/.box/queues`).
    public static func queuesDirectory() -> URL? {
        boxDirectory()?.appendingPathComponent("queues", isDirectory: true)
    }

    /// Resolves the default admin socket path (`~/.box/run/boxd.socket`).
    /// - Returns: Absolute path to the admin socket when derivable.
    public static func adminSocketPath() -> String? {
        #if os(Windows)
        return #"\\.\pipe\boxd-admin"#
        #else
        runDirectory()?.appendingPathComponent("boxd.socket").path
        #endif
    }
}
