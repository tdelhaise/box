#!/usr/bin/env swift

import Foundation

enum BumpError: Error, CustomStringConvertible {
    case missingArgument
    case invalidVersion(String)
    case packageNotFound(String)
    case commentNotFound
    case writeFailed(String)

    var description: String {
        switch self {
        case .missingArgument:
            return "Usage: scripts/bump_version.swift <new-version>"
        case .invalidVersion(let value):
            return "Invalid version string: \(value)"
        case .packageNotFound(let path):
            return "Unable to locate Package.swift at \(path)"
        case .commentNotFound:
            return "Could not find BOX_VERSION comment in Package.swift"
        case .writeFailed(let path):
            return "Failed to write updated Package.swift at \(path)"
        }
    }
}

func main() throws {
    guard CommandLine.arguments.count == 2 else {
        throw BumpError.missingArgument
    }
    let newVersion = CommandLine.arguments[1].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !newVersion.isEmpty else {
        throw BumpError.invalidVersion(newVersion)
    }

    let packagePath = FileManager.default.currentDirectoryPath + "/Package.swift"
    guard FileManager.default.fileExists(atPath: packagePath) else {
        throw BumpError.packageNotFound(packagePath)
    }

    let packageURL = URL(fileURLWithPath: packagePath)
    let contents = try String(contentsOf: packageURL, encoding: .utf8)

    let pattern = #"//\s*BOX_VERSION:\s*([A-Za-z0-9\.\-\+_]+)"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
        throw BumpError.invalidVersion(newVersion)
    }

    let fullRange = NSRange(location: 0, length: (contents as NSString).length)
    let matches = regex.matches(in: contents, options: [], range: fullRange)
    guard let match = matches.first, match.numberOfRanges >= 2 else {
        throw BumpError.commentNotFound
    }

    let updatedComment = "// BOX_VERSION: \(newVersion)"
    let replacementRange = match.range(at: 0)
    let updatedContents = (contents as NSString).replacingCharacters(in: replacementRange, with: updatedComment)

    do {
        try updatedContents.write(to: packageURL, atomically: true, encoding: .utf8)
    } catch {
        throw BumpError.writeFailed(packagePath)
    }

    FileHandle.standardOutput.write("Updated BOX_VERSION to \(newVersion)\n".data(using: .utf8)!)
}

do {
    try main()
} catch let error as BumpError {
    FileHandle.standardError.write("\(error.description)\n".data(using: .utf8)!)
    exit(1)
} catch {
    FileHandle.standardError.write("Unexpected error: \(error)\n".data(using: .utf8)!)
    exit(1)
}
