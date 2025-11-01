import XCTest
import Foundation
@testable import BoxCore

final class NoiseKeyStoreTests: XCTestCase {
    func testEnsureIdentityCreatesAndPersistsMaterial() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("box-keystore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let store = try BoxNoiseKeyStore(baseDirectory: tempDirectory)
        let firstIdentity = try await store.ensureIdentity(for: .node)
        XCTAssertEqual(firstIdentity.publicKey.count, 32)
        XCTAssertEqual(firstIdentity.secretKey.count, 32)

        let persistedURL = await store.identityURL(for: .node)
        XCTAssertTrue(FileManager.default.fileExists(atPath: persistedURL.path))

        let secondIdentity = try await store.ensureIdentity(for: .node)
        XCTAssertEqual(firstIdentity, secondIdentity, "ensureIdentity should return the persisted value when available")
    }

    func testLoadIdentityThrowsWhenMissing() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("box-keystore-missing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let store = try BoxNoiseKeyStore(baseDirectory: tempDirectory)
        do {
            _ = try await store.loadIdentity(for: .client)
            XCTFail("Expected loadIdentity to throw when no material exists")
        } catch BoxNoiseKeyStore.StoreError.storageUnavailable {
            // expected path
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPersistLinkCreatesSignatures() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("box-keystore-links-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let store = try BoxNoiseKeyStore(baseDirectory: tempDirectory)
        let userMaterial = try await store.regenerateIdentity(for: .client)
        let nodeMaterial = try await store.regenerateIdentity(for: .node)
        let userUUID = UUID()
        let nodeUUID = UUID()

        try await store.persistLink(
            userUUID: userUUID,
            nodeUUID: nodeUUID,
            userMaterial: userMaterial,
            nodeMaterial: nodeMaterial
        )

        let linkURL = await store.identityURL(for: .node).deletingLastPathComponent().appendingPathComponent("identity-links.json", isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: linkURL.path))

        let data = try Data(contentsOf: linkURL)
        let decoded = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        let algorithm = decoded?["algorithm"] as? String
        XCTAssertEqual(algorithm, "ed25519")
        XCTAssertEqual(decoded?["userUUID"] as? String, userUUID.uuidString.uppercased())
        XCTAssertEqual(decoded?["nodeUUID"] as? String, nodeUUID.uuidString.uppercased())
        XCTAssertNotNil(decoded?["userSignature"] as? String)
        XCTAssertNotNil(decoded?["nodeSignature"] as? String)
    }
}
