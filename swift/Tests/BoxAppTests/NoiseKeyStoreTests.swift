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
}
