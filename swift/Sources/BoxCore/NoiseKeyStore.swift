import Foundation

/// Describes persisted identity material used for Noise handshakes.
public struct BoxIdentityMaterial: Codable, Equatable, Sendable {
    /// Public key bytes (currently 32 bytes placeholder).
    public var publicKey: [UInt8]
    /// Secret key bytes (currently 32 bytes placeholder).
    public var secretKey: [UInt8]
}

/// Distinguishes between the supported identity roles.
public enum BoxIdentityRole: String, Sendable {
    case node
    case client

    fileprivate var fileName: String {
        switch self {
        case .node:
            return "node.identity.json"
        case .client:
            return "client.identity.json"
        }
    }
}

/// Stores Noise identity key material under `~/.box/keys`.
public actor BoxNoiseKeyStore {
    public enum StoreError: Error, LocalizedError {
        case storageUnavailable(String)
        case corrupted(String)

        public var errorDescription: String? {
            switch self {
            case .storageUnavailable(let message):
                return message
            case .corrupted(let message):
                return message
            }
        }
    }

    private let baseDirectory: URL
    private let fileManager = FileManager.default

    /// Creates a key store rooted at the supplied directory (defaults to `~/.box/keys`).
    public init(baseDirectory: URL? = nil) throws {
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else if let resolved = BoxPaths.boxDirectory()?.appendingPathComponent("keys", isDirectory: true) {
            self.baseDirectory = resolved
        } else {
            throw StoreError.storageUnavailable("Unable to resolve ~/.box directory for key storage.")
        }
        try Self.ensureDirectory(at: self.baseDirectory)
    }

    /// Returns the file URL associated with a given role.
    public func identityURL(for role: BoxIdentityRole) -> URL {
        baseDirectory.appendingPathComponent(role.fileName, isDirectory: false)
    }

    /// Loads the identity material, creating a fresh one when missing.
    public func ensureIdentity(for role: BoxIdentityRole) throws -> BoxIdentityMaterial {
        if let existing = try loadIdentityIfPresent(for: role) {
            return existing
        }
        let generated = generateIdentityMaterial()
        try persist(generated, for: role)
        return generated
    }

    /// Loads the existing identity material.
    public func loadIdentity(for role: BoxIdentityRole) throws -> BoxIdentityMaterial {
        if let existing = try loadIdentityIfPresent(for: role) {
            return existing
        }
        throw StoreError.storageUnavailable("Identity not found for role \(role.rawValue).")
    }

    // MARK: - Private helpers

    private static func ensureDirectory(at url: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            if !isDirectory.boolValue {
                throw StoreError.storageUnavailable("Key path is not a directory: \(url.path)")
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

    private func loadIdentityIfPresent(for role: BoxIdentityRole) throws -> BoxIdentityMaterial? {
        let url = identityURL(for: role)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            let record = try JSONDecoder().decode(IdentityFile.self, from: data)
            return try record.material()
        } catch {
            throw StoreError.corrupted("Unable to decode identity file for role \(role.rawValue): \(error)")
        }
    }

    private func persist(_ material: BoxIdentityMaterial, for role: BoxIdentityRole) throws {
        let url = identityURL(for: role)
        let record = IdentityFile(material: material)
        let data = try JSONEncoder().encode(record)
        try data.write(to: url, options: .atomic)
#if !os(Windows)
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: url.path)
#endif
    }

    private func generateIdentityMaterial() -> BoxIdentityMaterial {
        BoxIdentityMaterial(publicKey: randomBytes(length: 32), secretKey: randomBytes(length: 32))
    }

    private func randomBytes(length: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<length).map { _ in UInt8.random(in: UInt8.min...UInt8.max, using: &generator) }
    }

    private struct IdentityFile: Codable {
        var publicKey: String
        var secretKey: String

        init(material: BoxIdentityMaterial) {
            self.publicKey = Self.hexString(from: material.publicKey)
            self.secretKey = Self.hexString(from: material.secretKey)
        }

        func material() throws -> BoxIdentityMaterial {
            guard let publicBytes = Self.bytes(fromHex: publicKey), let secretBytes = Self.bytes(fromHex: secretKey) else {
                throw StoreError.corrupted("Identity file contains invalid hex data.")
            }
            return BoxIdentityMaterial(publicKey: publicBytes, secretKey: secretBytes)
        }

        private static func hexString(from bytes: [UInt8]) -> String {
            bytes.map { String(format: "%02x", $0) }.joined()
        }

        private static func bytes(fromHex string: String) -> [UInt8]? {
            let characters = Array(string)
            guard characters.count % 2 == 0 else { return nil }
            var result: [UInt8] = []
            result.reserveCapacity(characters.count / 2)
            var index = 0
            while index < characters.count {
                let byteString = String(characters[index..<(index + 2)])
                guard let value = UInt8(byteString, radix: 16) else { return nil }
                result.append(value)
                index += 2
            }
            return result
        }
    }
}
