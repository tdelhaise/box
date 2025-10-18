import BoxCore
import Logging
import NIOCore
import XCTest

/// Unit tests covering utility helpers and the Box protocol codec.
final class BoxAppTests: XCTestCase {
    /// Ensures that nil log levels default to `.info`.
    func testLogLevelParsingDefaultsToInfo() {
        let level = Logger.Level(logLevelString: nil)
        XCTAssertEqual(level, .info)
    }

    /// Ensures that explicit levels map correctly.
    func testLogLevelParsingRecognisesDebug() {
        let level = Logger.Level(logLevelString: "debug")
        XCTAssertEqual(level, .debug)
    }

    /// Verifies that frames round-trip through the codec.
    func testFrameRoundTrip() throws {
        var payload = ByteBufferAllocator().buffer(capacity: 0)
        payload.writeString("test")
        let requestId = UUID()
        let nodeId = UUID()
        let userId = UUID()
        let frame = BoxCodec.Frame(command: .status, requestId: requestId, nodeId: nodeId, userId: userId, payload: payload)
        var encoded = BoxCodec.encodeFrame(frame, allocator: ByteBufferAllocator())
        let decoded = try BoxCodec.decodeFrame(from: &encoded)
        XCTAssertEqual(decoded.command, .status)
        XCTAssertEqual(decoded.requestId, requestId)
        XCTAssertEqual(decoded.nodeId, nodeId)
        XCTAssertEqual(decoded.userId, userId)
        XCTAssertEqual(decoded.payload.getString(at: 0, length: decoded.payload.readableBytes), "test")
    }

    /// Verifies PUT payload encoding/decoding symmetry.
    func testPutPayloadRoundTrip() throws {
        let allocator = ByteBufferAllocator()
        let payload = BoxCodec.PutPayload(queuePath: "/message", contentType: "text/plain", data: Array("hello".utf8))
        var buffer = BoxCodec.encodePutPayload(payload, allocator: allocator)
        let decoded = try BoxCodec.decodePutPayload(from: &buffer)
        XCTAssertEqual(decoded.queuePath, payload.queuePath)
        XCTAssertEqual(decoded.contentType, payload.contentType)
        XCTAssertEqual(decoded.data, payload.data)
    }

    /// Verifies STATUS payload encoding/decoding symmetry.
    func testStatusPayloadRoundTrip() throws {
        let allocator = ByteBufferAllocator()
        var buffer = BoxCodec.encodeStatusPayload(status: .ok, message: "pong", allocator: allocator)
        let decoded = try BoxCodec.decodeStatusPayload(from: &buffer)
        XCTAssertEqual(decoded.status, .ok)
        XCTAssertEqual(decoded.message, "pong")
    }
}
