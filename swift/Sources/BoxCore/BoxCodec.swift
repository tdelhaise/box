import Foundation
import NIOCore

/// Errors thrown while decoding or encoding Box protocol frames.
public enum BoxCodecError: Error {
    /// The incoming payload is shorter than required for the requested operation.
    case truncatedPayload
    /// The frame header is malformed or contains an unsupported value.
    case malformedHeader
    /// The payload contains non UTF-8 text where UTF-8 was required.
    case invalidUTF8
    /// The payload declares lengths that cannot be satisfied by the buffer.
    case invalidLength
    /// The command identifier in the frame is unknown.
    case unsupportedCommand
    /// The frame advertises an unsupported version.
    case unsupportedVersion
    /// The hello payload declares more versions than the protocol allows.
    case unsupportedVersionCount
}

/// Codec responsible for serialising and deserialising Box protocol datagrams.
public enum BoxCodec {
    /// Magic byte identifying Box frames.
    public static let magic: UInt8 = 0x42
    /// Protocol version currently supported by the Swift implementation.
    public static let version: UInt8 = 0x01
    /// Header size after the length field (command + request identifier + node/user identifiers).
    private static let headerRemainderSize: Int = 52

    /// Enumeration of the command identifiers defined by the protocol.
    public enum Command: UInt32 {
        /// HELLO handshake command.
        case hello = 1
        /// PUT command (store an object or send it back to a client).
        case put = 2
        /// GET command (request an object).
        case get = 3
        /// DELETE command (not yet implemented in Swift).
        case delete = 4
        /// STATUS command (transport control / pong).
        case status = 5
        /// SEARCH command (reserved for future work).
        case search = 6
        /// BYE command for teardown.
        case bye = 7
        /// LOCATE command (Location Service query).
        case locate = 8
    }

    /// Status codes used in HELLO/STATUS payloads.
    public enum Status: UInt8 {
        /// Success.
        case ok = 0
        /// Peer is not authenticated.
        case unauthorized = 1
        /// Peer is forbidden from accessing the resource.
        case forbidden = 2
        /// Resource could not be found.
        case notFound = 3
        /// Conflict while processing the request.
        case conflict = 4
        /// Generic bad request.
        case badRequest = 5
        /// Payload too large.
        case tooLarge = 6
        /// Rate limited.
        case rateLimited = 7
        /// Internal processing failure.
        case internalError = 8
    }

    /// Represents a decoded frame without interpreting the payload.
    public struct Frame {
        /// Command associated with the frame.
        public var command: Command
        /// Request identifier chosen by the sender.
        public var requestId: UUID
        /// Node identifier of the sending machine.
        public var nodeId: UUID
        /// User identifier on whose behalf the sender operates.
        public var userId: UUID
        /// Payload slice referencing the underlying datagram.
        public var payload: ByteBuffer

        /// Creates a new frame value.
        /// - Parameters:
        ///   - command: High-level command.
        ///   - requestId: Request identifier.
        ///   - nodeId: Origin node identifier.
        ///   - userId: Origin user identifier.
        ///   - payload: Raw payload buffer.
        public init(command: Command, requestId: UUID, nodeId: UUID, userId: UUID, payload: ByteBuffer) {
            self.command = command
            self.requestId = requestId
            self.nodeId = nodeId
            self.userId = userId
            self.payload = payload
        }
    }

    /// Payload of a HELLO frame.
    public struct HelloPayload {
        /// Status code advertised by the sender.
        public var status: Status
        /// List of protocol versions supported by the sender.
        public var supportedVersions: [UInt16]

        /// Creates a new HELLO payload representation.
        /// - Parameters:
        ///   - status: Status code advertised by the sender.
        ///   - supportedVersions: List of protocol versions supported by the sender.
        public init(status: Status, supportedVersions: [UInt16]) {
            self.status = status
            self.supportedVersions = supportedVersions
        }
    }

    /// Payload of a STATUS frame.
    public struct StatusPayload {
        /// Status code advertised by the sender.
        public var status: Status
        /// Optional ASCII/UTF-8 message.
        public var message: String

        /// Creates a new STATUS payload representation.
        /// - Parameters:
        ///   - status: Status code advertised by the sender.
        ///   - message: Optional status message.
        public init(status: Status, message: String) {
            self.status = status
            self.message = message
        }
    }

    /// Payload of a PUT frame.
    public struct PutPayload {
        /// Queue path describing the logical destination.
        public var queuePath: String
        /// Content type associated with the payload.
        public var contentType: String
        /// Raw payload bytes.
        public var data: [UInt8]

        /// Creates a new PUT payload representation.
        /// - Parameters:
        ///   - queuePath: Logical queue path.
        ///   - contentType: Content type string.
        ///   - data: Raw payload bytes.
        public init(queuePath: String, contentType: String, data: [UInt8]) {
            self.queuePath = queuePath
            self.contentType = contentType
            self.data = data
        }
    }

    /// Payload of a GET frame.
    public struct GetPayload {
        /// Queue path requested by the client.
        public var queuePath: String

        /// Creates a new GET payload representation.
        /// - Parameter queuePath: Queue path requested by the client.
        public init(queuePath: String) {
            self.queuePath = queuePath
        }
    }

    /// Payload of a LOCATE/SEARCH frame.
    public struct LocatePayload {
        /// Node identifier being resolved.
        public var nodeUUID: UUID

        /// Creates a new Locate payload representation.
        /// - Parameter nodeUUID: Node identifier to resolve.
        public init(nodeUUID: UUID) {
            self.nodeUUID = nodeUUID
        }
    }

    /// Decodes a frame from the provided datagram buffer.
    /// - Parameter buffer: Datagram buffer read from the network.
    /// - Returns: A frame containing the command, request identifier and payload slice.
    /// - Throws: `BoxCodecError` if the header is malformed or incomplete.
    public static func decodeFrame(from buffer: inout ByteBuffer) throws -> Frame {
        guard let magicByte: UInt8 = buffer.readInteger(),
              let versionByte: UInt8 = buffer.readInteger(),
              let totalLength: UInt32 = buffer.readInteger(endianness: .big, as: UInt32.self),
              let rawCommand: UInt32 = buffer.readInteger(endianness: .big, as: UInt32.self) else {
            throw BoxCodecError.malformedHeader
        }

        guard magicByte == magic else {
            throw BoxCodecError.malformedHeader
        }
        guard versionByte == version else {
            throw BoxCodecError.unsupportedVersion
        }
        guard let command = Command(rawValue: rawCommand) else {
            throw BoxCodecError.unsupportedCommand
        }

        guard let requestId = readUUID(from: &buffer),
              let nodeId = readUUID(from: &buffer),
              let userId = readUUID(from: &buffer) else {
            throw BoxCodecError.malformedHeader
        }

        let payloadLength = Int(totalLength) - headerRemainderSize
        guard payloadLength >= 0 else {
            throw BoxCodecError.invalidLength
        }
        guard let payloadSlice = buffer.readSlice(length: payloadLength) else {
            throw BoxCodecError.truncatedPayload
        }

        return Frame(command: command, requestId: requestId, nodeId: nodeId, userId: userId, payload: payloadSlice)
    }

    /// Encodes a frame into a new datagram buffer.
    /// - Parameters:
    ///   - frame: Frame ready to be serialised.
    ///   - allocator: Byte buffer allocator from the channel.
    /// - Returns: A datagram buffer containing the serialised frame.
    public static func encodeFrame(_ frame: Frame, allocator: ByteBufferAllocator) -> ByteBuffer {
        var payloadCopy = frame.payload
        let payloadLength = payloadCopy.readableBytes
        var buffer = allocator.buffer(capacity: 2 + 4 + headerRemainderSize + payloadLength)
        buffer.writeInteger(magic)
        buffer.writeInteger(version)
        buffer.writeInteger(UInt32(headerRemainderSize + payloadLength), endianness: .big)
        buffer.writeInteger(frame.command.rawValue, endianness: .big)
        writeUUID(frame.requestId, into: &buffer)
        writeUUID(frame.nodeId, into: &buffer)
        writeUUID(frame.userId, into: &buffer)
        buffer.writeBuffer(&payloadCopy)
        return buffer
    }

    private static func readUUID(from buffer: inout ByteBuffer) -> UUID? {
        guard let bytes = buffer.readBytes(length: 16) else {
            return nil
        }
        return bytes.withUnsafeBytes { pointer -> UUID? in
            guard pointer.count == 16 else {
                return nil
            }
            let tuple = pointer.load(as: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8).self)
            return UUID(uuid: tuple)
        }
    }

    private static func writeUUID(_ uuid: UUID, into buffer: inout ByteBuffer) {
        var value = uuid.uuid
        let bytes = withUnsafeBytes(of: &value) { pointer in
            Array(pointer)
        }
        buffer.writeBytes(bytes)
    }

    /// Encodes a HELLO payload into a buffer.
    /// - Parameters:
    ///   - status: Status code for the HELLO response.
    ///   - versions: List of supported protocol versions (max 255 entries).
    ///   - allocator: Byte buffer allocator from the channel.
    /// - Throws: `BoxCodecError.unsupportedVersionCount` if the count exceeds 255.
    /// - Returns: A buffer ready to be embedded in a frame.
    public static func encodeHelloPayload(
        status: Status,
        versions: [UInt16],
        allocator: ByteBufferAllocator
    ) throws -> ByteBuffer {
        guard versions.count <= 255 else {
            throw BoxCodecError.unsupportedVersionCount
        }
        var buffer = allocator.buffer(capacity: 2 + versions.count * MemoryLayout<UInt16>.size)
        buffer.writeInteger(status.rawValue)
        buffer.writeInteger(UInt8(versions.count))
        for versionValue in versions {
            buffer.writeInteger(versionValue, endianness: .big)
        }
        return buffer
    }

    /// Decodes a HELLO payload from the supplied buffer slice.
    /// - Parameter payload: Payload slice referencing the HELLO buffer.
    /// - Returns: A strongly typed HELLO payload.
    /// - Throws: `BoxCodecError` when the payload is malformed.
    public static func decodeHelloPayload(from payload: inout ByteBuffer) throws -> HelloPayload {
        guard let rawStatus: UInt8 = payload.readInteger(),
              let count: UInt8 = payload.readInteger() else {
            throw BoxCodecError.truncatedPayload
        }
        var versions: [UInt16] = []
        versions.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let versionValue: UInt16 = payload.readInteger(endianness: .big, as: UInt16.self) else {
                throw BoxCodecError.truncatedPayload
            }
            versions.append(versionValue)
        }
        guard let status = Status(rawValue: rawStatus) else {
            throw BoxCodecError.malformedHeader
        }
        return HelloPayload(status: status, supportedVersions: versions)
    }

    /// Encodes a STATUS payload.
    /// - Parameters:
    ///   - status: Status code to advertise.
    ///   - message: Optional UTF-8 message string.
    ///   - allocator: Byte buffer allocator from the channel.
    /// - Returns: The encoded payload buffer.
    public static func encodeStatusPayload(
        status: Status,
        message: String,
        allocator: ByteBufferAllocator
    ) -> ByteBuffer {
        let messageBytes = Array(message.utf8)
        var buffer = allocator.buffer(capacity: 1 + messageBytes.count)
        buffer.writeInteger(status.rawValue)
        buffer.writeBytes(messageBytes)
        return buffer
    }

    /// Decodes a STATUS payload from the supplied buffer.
    /// - Parameter payload: Payload slice referencing the STATUS buffer.
    /// - Returns: The typed STATUS payload.
    /// - Throws: `BoxCodecError` for malformed data or invalid UTF-8 strings.
    public static func decodeStatusPayload(from payload: inout ByteBuffer) throws -> StatusPayload {
        guard let rawStatus: UInt8 = payload.readInteger() else {
            throw BoxCodecError.truncatedPayload
        }
        let messageData = payload.readBytes(length: payload.readableBytes) ?? []
        guard let message = String(bytes: messageData, encoding: .utf8) else {
            throw BoxCodecError.invalidUTF8
        }
        guard let status = Status(rawValue: rawStatus) else {
            throw BoxCodecError.malformedHeader
        }
        return StatusPayload(status: status, message: message)
    }

    /// Encodes a PUT payload (queue path, content type, payload bytes).
    /// - Parameters:
    ///   - payload: Typed PUT payload.
    ///   - allocator: Byte buffer allocator from the channel.
    /// - Returns: Encoded PUT payload buffer.
    public static func encodePutPayload(
        _ payload: PutPayload,
        allocator: ByteBufferAllocator
    ) -> ByteBuffer {
        let queueBytes = Array(payload.queuePath.utf8)
        let typeBytes = Array(payload.contentType.utf8)
        let dataBytes = payload.data

        var buffer = allocator.buffer(
            capacity: 2 + queueBytes.count + 2 + typeBytes.count + 4 + dataBytes.count
        )
        buffer.writeInteger(UInt16(queueBytes.count), endianness: .big)
        buffer.writeBytes(queueBytes)
        buffer.writeInteger(UInt16(typeBytes.count), endianness: .big)
        buffer.writeBytes(typeBytes)
        buffer.writeInteger(UInt32(dataBytes.count), endianness: .big)
        buffer.writeBytes(dataBytes)
        return buffer
    }

    /// Decodes a PUT payload from the supplied buffer slice.
    /// - Parameter payload: Payload slice referencing the PUT buffer.
    /// - Returns: Typed PUT payload.
    /// - Throws: `BoxCodecError` when lengths do not match or UTF-8 decoding fails.
    public static func decodePutPayload(from payload: inout ByteBuffer) throws -> PutPayload {
        guard let queueLength: UInt16 = payload.readInteger(endianness: .big, as: UInt16.self),
              let queueBytes = payload.readBytes(length: Int(queueLength)),
              let contentTypeLength: UInt16 = payload.readInteger(endianness: .big, as: UInt16.self),
              let contentTypeBytes = payload.readBytes(length: Int(contentTypeLength)),
              let dataLength: UInt32 = payload.readInteger(endianness: .big, as: UInt32.self),
              let dataBytes = payload.readBytes(length: Int(dataLength)) else {
            throw BoxCodecError.truncatedPayload
        }

        guard let queuePath = String(bytes: queueBytes, encoding: .utf8),
              let contentType = String(bytes: contentTypeBytes, encoding: .utf8) else {
            throw BoxCodecError.invalidUTF8
        }

        return PutPayload(queuePath: queuePath, contentType: contentType, data: dataBytes)
    }

    /// Encodes a GET payload (queue path).
    /// - Parameters:
    ///   - payload: Typed GET payload.
    ///   - allocator: Byte buffer allocator from the channel.
    /// - Returns: Encoded GET payload buffer.
    public static func encodeGetPayload(
        _ payload: GetPayload,
        allocator: ByteBufferAllocator
    ) -> ByteBuffer {
        let queueBytes = Array(payload.queuePath.utf8)
        var buffer = allocator.buffer(capacity: 2 + queueBytes.count)
        buffer.writeInteger(UInt16(queueBytes.count), endianness: .big)
        buffer.writeBytes(queueBytes)
        return buffer
    }

    /// Decodes a GET payload from the supplied buffer slice.
    /// - Parameter payload: Payload slice referencing the GET buffer.
    /// - Returns: Typed GET payload.
    /// - Throws: `BoxCodecError` when the payload is malformed.
    public static func decodeGetPayload(from payload: inout ByteBuffer) throws -> GetPayload {
        guard let queueLength: UInt16 = payload.readInteger(endianness: .big, as: UInt16.self),
              let queueBytes = payload.readBytes(length: Int(queueLength)) else {
            throw BoxCodecError.truncatedPayload
        }
        guard let queuePath = String(bytes: queueBytes, encoding: .utf8) else {
            throw BoxCodecError.invalidUTF8
        }
        return GetPayload(queuePath: queuePath)
    }

    /// Encodes a Locate payload (target node UUID).
    /// - Parameters:
    ///   - payload: Typed Locate payload.
    ///   - allocator: Byte buffer allocator from the channel.
    /// - Returns: Encoded Locate payload buffer.
    public static func encodeLocatePayload(
        _ payload: LocatePayload,
        allocator: ByteBufferAllocator
    ) -> ByteBuffer {
        var buffer = allocator.buffer(capacity: 16)
        writeUUID(payload.nodeUUID, into: &buffer)
        return buffer
    }

    /// Decodes a Locate payload from the supplied buffer slice.
    /// - Parameter payload: Payload slice referencing the Locate buffer.
    /// - Returns: Typed Locate payload.
    /// - Throws: `BoxCodecError` when the payload is malformed.
    public static func decodeLocatePayload(from payload: inout ByteBuffer) throws -> LocatePayload {
        guard let nodeUUID = readUUID(from: &payload) else {
            throw BoxCodecError.truncatedPayload
        }
        return LocatePayload(nodeUUID: nodeUUID)
    }
}
