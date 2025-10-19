import Foundation

#if os(Linux)
import Glibc
#elseif os(Windows)
import WinSDK
#else
import Darwin
#endif

enum PortMappingUtilities {
    static func parseSSDPResponse(_ data: Data) -> [String: String] {
        guard let response = String(data: data, encoding: .utf8) else { return [:] }
        let normalized = response.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n")
        var headers: [String: String] = [:]
        for line in lines {
            if let separatorIndex = line.firstIndex(of: ":") {
                let name = line[..<separatorIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let value = line[line.index(after: separatorIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
                headers[name] = value
            }
        }
        return headers
    }

    static func escapeXML(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "&": result.append("&amp;")
            case "<": result.append("&lt;")
            case ">": result.append("&gt;")
            case "\"": result.append("&quot;")
            case "'": result.append("&apos;")
            default: result.append(character)
            }
        }
        return result
    }

    static func decodeLittleEndianIPv4(_ hex: String) -> String? {
        guard hex.count == 8, let value = UInt32(hex, radix: 16) else { return nil }
        let byte0 = UInt8(value & 0xFF)
        let byte1 = UInt8((value >> 8) & 0xFF)
        let byte2 = UInt8((value >> 16) & 0xFF)
        let byte3 = UInt8((value >> 24) & 0xFF)
        return "\(byte0).\(byte1).\(byte2).\(byte3)"
    }

    static func defaultGateway(fromProcNetRoute contents: String) -> String? {
        let lines = contents.split(whereSeparator: \.isNewline)
        guard lines.count > 1 else { return nil }
        for line in lines.dropFirst() {
            let columns = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard columns.count >= 3 else { continue }
            let destinationHex = String(columns[1])
            let gatewayHex = String(columns[2])
            if destinationHex.caseInsensitiveCompare("00000000") == .orderedSame {
                if let address = decodeLittleEndianIPv4(gatewayHex) {
                    return address
                }
            }
        }
        return nil
    }

    static func ipv4MappedAddress(_ ipv4: String) -> [UInt8]? {
        var addr = in_addr()
        guard inet_pton(AF_INET, ipv4, &addr) == 1 else { return nil }
        let hostOrder = UInt32(bigEndian: addr.s_addr)
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[10] = 0xff
        bytes[11] = 0xff
        bytes[12] = UInt8((hostOrder >> 24) & 0xff)
        bytes[13] = UInt8((hostOrder >> 16) & 0xff)
        bytes[14] = UInt8((hostOrder >> 8) & 0xff)
        bytes[15] = UInt8(hostOrder & 0xff)
        return bytes
    }

    static func ipv6BytesToIPv4(_ bytes: [UInt8]) -> String? {
        guard bytes.count == 16 else { return nil }
        let prefixZero = bytes.prefix(10).allSatisfy { $0 == 0 }
        if prefixZero && bytes[10] == 0xff && bytes[11] == 0xff {
            return "\(bytes[12]).\(bytes[13]).\(bytes[14]).\(bytes[15])"
        }
        return nil
    }

    static func randomNonce(length: Int) -> [UInt8] {
        precondition(length >= 0)
        var generator = SystemRandomNumberGenerator()
        return (0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) }
    }
}
