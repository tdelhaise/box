import Foundation

#if os(Linux)
import Glibc
#else
import Darwin
#endif

public func iso8601String(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    return formatter.string(from: date)
}

public func numericHostString(for address: UnsafePointer<sockaddr>) -> String? {
    var host: [CChar] = Array(repeating: 0, count: Int(NI_MAXHOST))
    guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else {
        return nil
    }
    let trimmedBytes = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: trimmedBytes, as: UTF8.self)
}