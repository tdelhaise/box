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
    #if os(Linux)
    let socklen: socklen_t
    switch Int32(address.pointee.sa_family) {
    case AF_INET:
        socklen = socklen_t(MemoryLayout<sockaddr_in>.size)
    case AF_INET6:
        socklen = socklen_t(MemoryLayout<sockaddr_in6>.size)
    default:
        return nil
    }
    guard getnameinfo(address, socklen, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else {
        return nil
    }
    #else
    guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else {
        return nil
    }
    #endif
    let trimmedBytes = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: trimmedBytes, as: UTF8.self)
}