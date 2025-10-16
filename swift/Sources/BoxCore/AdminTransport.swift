import Foundation

#if canImport(Glibc)
import Glibc
#elseif os(Windows)
import WinSDK
#elseif canImport(Darwin)
import Darwin
#endif

/// Errors surfaced by the admin transport abstraction.
public enum BoxAdminTransportError: Error {
    /// Underlying system call could not create a socket descriptor.
    case socketCreationFailed
    /// Connection to the admin endpoint failed (path and errno provided when available).
    case connectionFailed(path: String, code: Int32)
    /// Writing the command to the admin transport has failed.
    case writeFailed
    /// Reading the response from the admin transport has failed.
    case readFailed
    /// The response payload was not valid UTF-8.
    case invalidUTF8
    /// Placeholder for platforms that do not yet provide an implementation.
    case unsupportedPlatform
}

public extension BoxAdminTransportError {
    /// Human readable description suitable for CLI error surfaces.
    var readableDescription: String {
        switch self {
        case .socketCreationFailed:
            return "failed to create admin socket"
        case .connectionFailed(let path, let code):
            return "unable to connect to admin endpoint at \(path) (errno: \(code))"
        case .writeFailed:
            return "unable to send request to admin endpoint"
        case .readFailed:
            return "unable to read response from admin endpoint"
        case .invalidUTF8:
            return "admin response was not valid UTF-8"
        case .unsupportedPlatform:
            return "admin transport not available on this platform"
        }
    }
}

/// Defines a minimal transport interface used by `box admin` commands.
public protocol BoxAdminTransport {
    /// Sends an admin command and returns the plain-text response.
    /// - Parameter command: Command string (without trailing newline).
    func send(command: String) throws -> String
}

/// Factory responsible for providing a platform-appropriate transport implementation.
public enum BoxAdminTransportFactory {
    /// Creates a transport suitable for the current platform.
    /// - Parameter socketPath: Socket path or transport identifier.
    /// - Returns: Concrete transport instance.
    public static func makeTransport(socketPath: String) -> any BoxAdminTransport {
        #if os(Windows)
        return WindowsAdminTransport(socketPath: socketPath)
        #else
        return UnixDomainAdminTransport(socketPath: socketPath)
        #endif
    }
}

/// Unix domain socket based transport used on Linux and macOS.
public struct UnixDomainAdminTransport: BoxAdminTransport {
    private let socketPath: String

    /// Creates a transport bound to the provided socket path.
    /// - Parameter socketPath: Filesystem path pointing to the admin socket.
    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public func send(command: String) throws -> String {
        #if canImport(Glibc)
        let streamType = Int32(SOCK_STREAM.rawValue)
        let fileDescriptor = Glibc.socket(AF_UNIX, streamType, 0)
        #elseif canImport(Darwin)
        let fileDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        #else
        throw BoxAdminTransportError.unsupportedPlatform
        #endif
        guard fileDescriptor >= 0 else {
            throw BoxAdminTransportError.socketCreationFailed
        }
        defer {
            #if canImport(Glibc)
            _ = Glibc.close(fileDescriptor)
            #elseif canImport(Darwin)
            _ = Darwin.close(fileDescriptor)
            #endif
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        var pathBytes = Array(socketPath.utf8)
        let maxLength = MemoryLayout.size(ofValue: address.sun_path) - 1
        if pathBytes.count > maxLength {
            pathBytes = Array(pathBytes.prefix(maxLength))
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            pathBytes.withUnsafeBytes { source in
                if let destination = buffer.baseAddress, let src = source.baseAddress {
                    memcpy(destination, src, pathBytes.count)
                }
            }
        }

        let socketLength = socklen_t(MemoryLayout.size(ofValue: address) - MemoryLayout.size(ofValue: address.sun_path) + pathBytes.count + 1)
        let connectResult = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                #if canImport(Glibc)
                return Glibc.connect(fileDescriptor, sockaddrPointer, socketLength)
                #elseif canImport(Darwin)
                return Darwin.connect(fileDescriptor, sockaddrPointer, socketLength)
                #endif
            }
        }
        guard connectResult == 0 else {
            #if canImport(Glibc)
            let code = errno
            #else
            let code = errno
            #endif
            throw BoxAdminTransportError.connectionFailed(path: socketPath, code: code)
        }

        let request = command + "\n"
        try request.withCString { pointer in
            let length = strlen(pointer)
            var totalWritten: size_t = 0
            while totalWritten < length {
                #if canImport(Glibc)
                let written = Glibc.write(fileDescriptor, pointer + totalWritten, length - totalWritten)
                #elseif canImport(Darwin)
                let written = Darwin.write(fileDescriptor, pointer + totalWritten, length - totalWritten)
                #endif
                if written <= 0 {
                    throw BoxAdminTransportError.writeFailed
                }
                totalWritten += size_t(written)
            }
        }

        var buffer = [UInt8](repeating: 0, count: 4096)
        var response = Data()
        while true {
            #if canImport(Glibc)
            let bytesRead = Glibc.read(fileDescriptor, &buffer, buffer.count)
            #elseif canImport(Darwin)
            let bytesRead = Darwin.read(fileDescriptor, &buffer, buffer.count)
            #endif
            if bytesRead < 0 {
                throw BoxAdminTransportError.readFailed
            }
            if bytesRead == 0 {
                break
            }
            response.append(buffer, count: Int(bytesRead))
        }

        guard let responseString = String(data: response, encoding: .utf8) else {
            throw BoxAdminTransportError.invalidUTF8
        }
        return responseString
    }
}

#if os(Windows)
/// Windows named-pipe transport used by `box admin` when running on Windows.
public struct WindowsAdminTransport: BoxAdminTransport {
    private let socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public func send(command: String) throws -> String {
        return try socketPath.withCString(encodedAs: UTF16.self) { pointer -> String in
            var handle = CreateFileW(pointer, DWORD(GENERIC_READ | GENERIC_WRITE), DWORD(0), nil, DWORD(OPEN_EXISTING), DWORD(0), nil)
            var errorCode: DWORD = 0

            if handle == INVALID_HANDLE_VALUE {
                errorCode = GetLastError()
                if errorCode == ERROR_PIPE_BUSY {
                    let waitResult = WaitNamedPipeW(pointer, DWORD(5000))
                    if waitResult == 0 {
                        throw BoxAdminTransportError.connectionFailed(path: socketPath, code: Int32(GetLastError()))
                    }
                    handle = CreateFileW(pointer, DWORD(GENERIC_READ | GENERIC_WRITE), DWORD(0), nil, DWORD(OPEN_EXISTING), DWORD(0), nil)
                    errorCode = GetLastError()
                }
                if handle == INVALID_HANDLE_VALUE {
                    throw BoxAdminTransportError.connectionFailed(path: socketPath, code: Int32(errorCode))
                }
            }

            defer { CloseHandle(handle) }

            let request = command.hasSuffix("\n") ? command : command + "\n"
            let requestBytes = Array(request.utf8)
            var bytesWritten: DWORD = 0
            let writeSuccess = requestBytes.withUnsafeBytes { buffer -> Bool in
                guard let baseAddress = buffer.baseAddress else { return false }
                return WriteFile(handle, baseAddress, DWORD(buffer.count), &bytesWritten, nil)
            }
            if !writeSuccess || bytesWritten == 0 {
                throw BoxAdminTransportError.writeFailed
            }
            FlushFileBuffers(handle)

            var response = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)

            while true {
                var bytesRead: DWORD = 0
                let readSuccess = ReadFile(handle, &buffer, DWORD(buffer.count), &bytesRead, nil)
                if !readSuccess {
                    let readError = GetLastError()
                    if readError == ERROR_MORE_DATA {
                        response.append(buffer, count: Int(bytesRead))
                        continue
                    }
                    if readError == ERROR_BROKEN_PIPE {
                        break
                    }
                    throw BoxAdminTransportError.readFailed
                }
                if bytesRead == 0 {
                    break
                }
                response.append(buffer, count: Int(bytesRead))
                if Int(bytesRead) < buffer.count {
                    break
                }
            }

            guard let responseString = String(data: response, encoding: .utf8) else {
                throw BoxAdminTransportError.invalidUTF8
            }
            return responseString
        }
    }
}
#endif
