// swift/Sources/BoxServer/BoxServerStore.swift
// Implémentation persistante basée sur le filesystem
//
// Hypothèses de structure disque (sous la racine logique .box/queues):
//  - <root>/queues/<queueName>/
//      └── <timestamp>-<uuid>.json  (ex: 20251017T143015Z-0F2B6F6A-... .json)
//
// Format JSON minimal pour chaque message:
// {
//   "id": "UUID",
//   "contentType": "text/plain",
//   "content": "<base64>",
//   "createdAt": "2025-10-17T14:30:15Z",
//   "machineId": "UUID",
//   "userId": "UUID",
//   "userMetadata": { "key": "value", ... }
// }
//
// Concurrence:
//  - Cette classe est un 'actor' -> sûre entre threads au sein du même process.
//  - Écritures atomiques via fichier temporaire + remplacement.
//
// API proposée (à adapter si besoin à l'existant):
//  - init(root: URL)
//  - ensureQueue(_ name: String)
//  - put(_ object: BoxStoredObject, into queue: String) -> UUID
//  - get(queue: String, id: UUID) -> BoxStoredObject?
//  - popOldest(from queue: String) -> BoxStoredObject?
//  - listQueues() -> [String]
//  - list(queue: String, limit: Int?, offset: Int?) -> [BoxMessageRef]
//  - remove(queue: String, id: UUID)
//  - purge(queue: String)
//
import Foundation
import Logging

// MARK: - Models

public struct BoxStoredObject: Codable, Sendable {
	/// this is the uniqu identifier of the message when it was propagate on the wire.
	public let id: UUID
	/// this is a conventional text description of the type of data inside this object.
	public let contentType: String
	/// the real data ...
	public let data: [UInt8]
	/// The creation date
	public let createdAt: Date
	/// The Box node Id of the machine who was at the origin of those data.
	public let nodeId: UUID
	/// The Box user id of the sender
	public let userId: UUID
	/// A dictionary of additionnal data if any are required
	public var userMetadata: [String:String]? // libre pour infos additionnelles
	
	public init(
		id: UUID = UUID(),
		contentType: String,
		data: [UInt8],
		createdAt: Date = Date(),
		nodeId: UUID,
		userId: UUID,
		userMetadata: [String:String]? = nil
	) {
		self.id = id
		self.contentType = contentType
		self.data = data
		self.createdAt = createdAt
		self.nodeId = nodeId
		self.userId = userId
		self.userMetadata = userMetadata
	}
}

public struct BoxMessageRef: Sendable, Hashable, Codable {
	public let id: UUID
	public let queue: String
	public let createdAt: Date
	public let url: URL // chemin du fichier sur disque
}

// MARK: - Internal Codable Wire Model

private struct DiskMessage: Codable {
	let id: UUID
	let contentType: String
	let content: String // base64
	let createdAt: Date
	let nodeId: UUID
	let userId: UUID
	let userMetadata: [String:String]?
}

// MARK: - Errors

public enum BoxStoreError: Error, LocalizedError {
	case queueNotFound(String)
	case objectNotFound(UUID)
	case invalidQueueName(String)
	case io(Error)
	case corrupted(URL)
	
	public var errorDescription: String? {
		switch self {
			case .queueNotFound(let q): return "Queue introuvable: \(q)"
			case .objectNotFound(let id): return "Objet introuvable: \(id)"
			case .invalidQueueName(let n): return "Nom de queue invalide: \(n)"
			case .io(let e): return "Erreur IO: \(e.localizedDescription)"
			case .corrupted(let url): return "Fichier corrompu: \(url.lastPathComponent)"
		}
	}
}

// MARK: - Store

public actor BoxServerStore {
	public let root: URL // .../.box/queues
	private let fm = FileManager.default
	private let encoder = JSONEncoder()
	private let decoder = JSONDecoder()
	private let logger: Logger
	
	public init(root: URL, logger: Logger = .init(label: "box.server.store")) async throws {
		self.root = root
		self.logger = logger
		encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
		encoder.dateEncodingStrategy = .iso8601
		decoder.dateDecodingStrategy = .iso8601
		try await ensureDirectoryExists(root)
		logger.info("store initialized", metadata: ["root": .string(root.path)])
	}
	
	// MARK: - Queue lifecycle
	
	@discardableResult
	public func ensureQueue(_ name: String) async throws -> URL {
		let sanitized = try sanitizeQueueName(name)
		let url = root.appendingPathComponent(sanitized, isDirectory: true)
		try await ensureDirectoryExists(url)
		if !fm.fileExists(atPath: url.path) {
			try await ensureDirectoryExists(url)
			logger.info("queue directory created", metadata: ["queue": .string(sanitized), "path": .string(url.path)])
		}
		return url
	}
	
	public func listQueues() async -> [String] {
		(try? fm.contentsOfDirectory(atPath: root.path))?.sorted() ?? []
	}
	
	// MARK: - Put/Get
	
	@discardableResult
	public func put(_ object: BoxStoredObject, into queue: String) async throws -> UUID {
		do {
		let qurl = try await ensureQueue(queue)
		let filename = makeFilename(for: object)
		let fileURL = qurl.appendingPathComponent(filename)
		let disk = DiskMessage(
			id: object.id,
			contentType: object.contentType,
			content: Data(object.data).base64EncodedString(),
			createdAt: object.createdAt,
			nodeId: object.nodeId,
			userId: object.userId,
			userMetadata: object.userMetadata )
		let data = try encoder.encode(disk)
		logger.debug("put", metadata: [
			"queue": .string(queue),
			"id": .string(object.id.uuidString),
			"bytes": .stringConvertible(object.data.count),
			"file": .string(fileURL.lastPathComponent)
			])
			try atomicWrite(data: data, to: fileURL)
			return object.id
		} catch {
			logger.error("put failed", metadata: ["queue": .string(queue),
												  "id": .string(object.id.uuidString),
												  "error": .string("\(error)")])
				throw error
		}
}
	
	public func get(queue: String, id: UUID) async throws -> BoxStoredObject {
		do {
			let qurl = root.appendingPathComponent(try sanitizeQueueName(queue), isDirectory: true)
			guard fm.fileExists(atPath: qurl.path) else { throw BoxStoreError.queueNotFound(queue) }
			let url = try findFileURL(for: id, in: qurl)
			logger.debug("get", metadata: ["queue": .string(queue), "id": .string(id.uuidString), "file": .string(url.lastPathComponent)])
			return try readObject(from: url)
		} catch {
			logger.error("get failed", metadata: ["queue": .string(queue), "id": .string(id.uuidString), "error": .string("\(error)")])
			throw error
		}
	}
	
	// Renvoie et supprime le plus ancien message (ordre déterminé par le préfixe timestamp du nom de fichier)
	public func popOldest(from queue: String) async throws -> BoxStoredObject? {
		do {
			let qurl = root.appendingPathComponent(try sanitizeQueueName(queue), isDirectory: true)
			guard fm.fileExists(atPath: qurl.path) else { throw BoxStoreError.queueNotFound(queue) }
			let files = try fm.contentsOfDirectory(at: qurl, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
			guard let first = files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first else { return nil }
			logger.debug("pop oldest", metadata: ["queue": .string(queue), "file": .string(first.lastPathComponent)])
			let obj = try readObject(from: first)
			try fm.removeItem(at: first)
			return obj
		} catch {
				logger.error("pop failed", metadata: ["queue": .string(queue), "error": .string("\(error)")])
				throw error
		}
	}
	
	public func remove(queue: String, id: UUID) async throws {
		do {
			let qurl = root.appendingPathComponent(try sanitizeQueueName(queue), isDirectory: true)
			guard fm.fileExists(atPath: qurl.path) else { throw BoxStoreError.queueNotFound(queue) }
			let url = try findFileURL(for: id, in: qurl)
			logger.debug("remove", metadata: ["queue": .string(queue), "id": .string(id.uuidString), "file": .string(url.lastPathComponent)])
			try fm.removeItem(at: url)
		} catch {
			logger.error("remove failed", metadata: ["queue": .string(queue), "id": .string(id.uuidString), "error": .string("\(error)")])
			throw error
        }
	}
	
	public func purge(queue: String) async throws {
		let qurl = root.appendingPathComponent(try sanitizeQueueName(queue), isDirectory: true)
		guard fm.fileExists(atPath: qurl.path) else { return }
		let urls = try fm.contentsOfDirectory(at: qurl, includingPropertiesForKeys: nil)
		logger.info("purge", metadata: ["queue": .string(queue), "count": .stringConvertible(urls.count)])
		for u in urls { try? fm.removeItem(at: u) }
	}
	
	public func read(reference: BoxMessageRef) async throws -> BoxStoredObject {
		try readObject(from: reference.url)
	}
	
	public func read(queue: String, id: UUID) async throws -> BoxStoredObject {
		let qurl = root.appendingPathComponent(try sanitizeQueueName(queue), isDirectory: true)
		guard fm.fileExists(atPath: qurl.path) else {
			throw BoxStoreError.queueNotFound(queue)
		}
		let fileURL = try findFileURL(for: id, in: qurl)
		return try readObject(from: fileURL)
	}
	
	public func list(queue: String, limit: Int? = nil, offset: Int? = nil) async throws -> [BoxMessageRef] {
		let qurl = root.appendingPathComponent(try sanitizeQueueName(queue), isDirectory: true)
		guard fm.fileExists(atPath: qurl.path) else { throw BoxStoreError.queueNotFound(queue) }
		let files = try fm.contentsOfDirectory(at: qurl, includingPropertiesForKeys: nil)
			.filter { $0.pathExtension == "json" }
			.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
		var sliced = files
		if let offset = offset, offset > 0 { sliced = Array(sliced.dropFirst(min(offset, sliced.count))) }
		if let limit = limit { sliced = Array(sliced.prefix(max(0, limit))) }
		return try sliced.map { url in
			let meta = try peekMeta(from: url)
			return BoxMessageRef(id: meta.id, queue: queue, createdAt: meta.createdAt, url: url)
		}
	}
	
	// MARK: - Helpers
	
	private func readObject(from url: URL) throws -> BoxStoredObject {
		do {
			let data = try Data(contentsOf: url)
			let disk = try decoder.decode(DiskMessage.self, from: data)
			guard let raw = Data(base64Encoded: disk.content) else { throw BoxStoreError.corrupted(url) }
			return BoxStoredObject(
				id: disk.id,
				contentType: disk.contentType,
				data: [UInt8](raw),
				createdAt: disk.createdAt,
				nodeId: disk.nodeId,
				userId: disk.userId,
				userMetadata: disk.userMetadata
			)
		} catch let e as BoxStoreError {
			throw e
		} catch {
			throw BoxStoreError.io(error)
		}
	}
	
	private func peekMeta(from url: URL) throws -> (id: UUID, createdAt: Date) {
		let data = try Data(contentsOf: url)
		let disk = try decoder.decode(DiskMessage.self, from: data)
		return (disk.id, disk.createdAt)
	}
	
	private func findFileURL(for id: UUID, in qurl: URL) throws -> URL {
		let pattern = "-\(id.uuidString.uppercased()).json"
		let files = try fm.contentsOfDirectory(at: qurl, includingPropertiesForKeys: nil)
		if let match = files.first(where: { $0.lastPathComponent.uppercased().hasSuffix(pattern) }) {
			return match
		}
		throw BoxStoreError.objectNotFound(id)
	}
	
	private func ensureDirectoryExists(_ url: URL) async throws {
		if !fm.fileExists(atPath: url.path) {
			try fm.createDirectory(at: url, withIntermediateDirectories: true)
		}
	}
	
	private func atomicWrite(data: Data, to url: URL) throws {
		let dir = url.deletingLastPathComponent()
		let tmp = dir.appendingPathComponent(".\(UUID().uuidString).tmp")
		do {
			try data.write(to: tmp, options: .atomic) // écrit atomique au niveau fichier temporaire
													  // replace assure un move atomique (si possible sur le FS)
			_ = try fm.replaceItemAt(url, withItemAt: tmp)
		} catch {
			// cleanup best-effort
			try? fm.removeItem(at: tmp)
			throw BoxStoreError.io(error)
		}
	}
	
	private func sanitizeQueueName(_ name: String) throws -> String {
		// Tolère un slash de tête: "/inbox" -> "inbox", mais interdit les slashes internes.
		var n = name.trimmingCharacters(in: .whitespacesAndNewlines)
		if n.hasPrefix("/") { while n.hasPrefix("/") { n.removeFirst() } }
		let invalid = CharacterSet(charactersIn: "/:\\\\?%*|\\\"<>")
		guard !n.isEmpty, n.rangeOfCharacter(from: invalid) == nil else {
			logger.warning("invalid queue name", metadata: ["name": .string(name)])
			throw BoxStoreError.invalidQueueName(name)
		}
		return n
	}
	
	private func makeFilename(for object: BoxStoredObject) -> String {
		let ts = iso8601BasicUTC(object.createdAt)
		return "\(ts)-\(object.id.uuidString).json"
	}
	
	private func iso8601BasicUTC(_ date: Date) -> String {
		// 20251017T143015Z (trisable lexicalement)
		var cal = Calendar(identifier: .iso8601)
		cal.timeZone = TimeZone(secondsFromGMT: 0)!
		let comps = cal.dateComponents([.year,.month,.day,.hour,.minute,.second], from: date)
		let y = String(format: "%04d", comps.year ?? 0)
		let m = String(format: "%02d", comps.month ?? 0)
		let d = String(format: "%02d", comps.day ?? 0)
		let H = String(format: "%02d", comps.hour ?? 0)
		let M = String(format: "%02d", comps.minute ?? 0)
		let S = String(format: "%02d", comps.second ?? 0)
		return "\(y)\(m)\(d)T\(H)\(M)\(S)Z"
	}
}

// MARK: - Exemple d'utilisation
#if DEBUG
func __example() async throws {
	let home = FileManager.default.homeDirectoryForCurrentUser
	let queuesRoot = home.appendingPathComponent(".box/queues", isDirectory: true)
	let store = try await BoxServerStore(root: queuesRoot)
	
	// Création d'un objet
	let payload = Array("Bonjour Box!".utf8)
	let obj = BoxStoredObject(contentType: "text/plain", data: payload, nodeId: UUID(), userId: UUID(), userMetadata: ["source":"unit-test"])
	
	// Enqueue
	let id = try await store.put(obj, into: "inbox")
	
	// Read back
	let fetched = try await store.get(queue: "inbox", id: id)
	assert(fetched.id == id)
	
	// POP oldest
	_ = try await store.popOldest(from: "inbox")
}
#endif
