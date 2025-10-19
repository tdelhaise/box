#if os(Windows)
import Foundation
import Logging
import NIOConcurrencyHelpers
import WinSDK

final class BoxAdminNamedPipeServer: @unchecked Sendable {
    private let path: String
    private let logger: Logger
    private let dispatcher: BoxAdminCommandDispatcher
    private let shouldStop = NIOLockedValueBox(false)
    private var task: Task<Void, Never>?
    private let securityAttributes: UnsafeMutablePointer<SECURITY_ATTRIBUTES>?
    private let securityDescriptor: PSECURITY_DESCRIPTOR?

    init(path: String, logger: Logger, dispatcher: BoxAdminCommandDispatcher) {
        self.path = path
        self.logger = logger
        self.dispatcher = dispatcher
        let securityContext = Self.makeSecurityAttributes(logger: logger)
        self.securityAttributes = securityContext?.attributes
        self.securityDescriptor = securityContext?.descriptor
    }

    func start() {
        guard task == nil else { return }
        let pipePath = path
        task = Task.detached { [weak self] in
            guard let self else { return }
            await self.runLoop(path: pipePath)
        }
    }

    func requestStop() {
        shouldStop.withLockedValue { $0 = true }
        Self.poke(path: path)
    }

    func waitUntilStopped() async {
        if let task {
            await task.value
        }
    }

    private func runLoop(path: String) async {
        let bufferSize: DWORD = 4096
        if securityAttributes == nil {
            logger.warning("admin pipe security: using default ACL (Windows descriptor creation failed)")
        }
        while !shouldStop.withLockedValue({ $0 }) {
            let handle: HANDLE = path.withCString(encodedAs: UTF16.self) { pointer in
                CreateNamedPipeW(
                    pointer,
                    DWORD(PIPE_ACCESS_DUPLEX),
                    DWORD(PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT),
                    DWORD(1),
                    bufferSize,
                    bufferSize,
                    DWORD(0),
                    securityAttributes
                )
            }

            if handle == INVALID_HANDLE_VALUE {
                let error = GetLastError()
                logger.error("admin pipe creation failed", metadata: ["error": "\(error)"])
                return
            }

            defer { CloseHandle(handle) }

            let connected = ConnectNamedPipe(handle, nil)
            if !connected {
                let error = GetLastError()
                if error != ERROR_PIPE_CONNECTED {
                    logger.warning("admin pipe connect failed", metadata: ["error": "\(error)"])
                    continue
                }
            }

            if shouldStop.withLockedValue({ $0 }) {
                DisconnectNamedPipe(handle)
                break
            }

            var buffer = [UInt8](repeating: 0, count: Int(bufferSize))
            var bytesRead: DWORD = 0
            let readResult = ReadFile(handle, &buffer, DWORD(buffer.count), &bytesRead, nil)
            if !readResult || bytesRead == 0 {
                DisconnectNamedPipe(handle)
                continue
            }

            let commandData = buffer.prefix(Int(bytesRead))
            let command = String(bytes: commandData, encoding: .utf8) ?? ""
            let responsePayload = await dispatcher.process(command)
            let response = responsePayload.hasSuffix("\n") ? responsePayload : responsePayload + "\n"
            let responseBytes = Array(response.utf8)
            var bytesWritten: DWORD = 0
            _ = WriteFile(handle, responseBytes, DWORD(responseBytes.count), &bytesWritten, nil)
            FlushFileBuffers(handle)
            DisconnectNamedPipe(handle)
        }
    }

    private static func poke(path: String) {
        path.withCString(encodedAs: UTF16.self) { pointer in
            let handle = CreateFileW(pointer, DWORD(GENERIC_READ | GENERIC_WRITE), DWORD(0), nil, DWORD(OPEN_EXISTING), DWORD(0), nil)
            if handle != INVALID_HANDLE_VALUE {
                CloseHandle(handle)
            }
        }
    }

    deinit {
        if let descriptor = securityDescriptor {
            _ = LocalFree(descriptor)
        }
        if let pointer = securityAttributes {
            pointer.deinitialize(count: 1)
            pointer.deallocate()
        }
    }

    private static func makeSecurityAttributes(
        logger: Logger
    ) -> (attributes: UnsafeMutablePointer<SECURITY_ATTRIBUTES>, descriptor: PSECURITY_DESCRIPTOR)? {
        let sddl = "D:P(A;;FA;;;SY)(A;;FA;;;OW)"
        return sddl.withCString(encodedAs: UTF16.self) { pointer -> (UnsafeMutablePointer<SECURITY_ATTRIBUTES>, PSECURITY_DESCRIPTOR)? in
            var securityDescriptor: PSECURITY_DESCRIPTOR?
            let conversionResult = ConvertStringSecurityDescriptorToSecurityDescriptorW(
                pointer,
                DWORD(SDDL_REVISION_1),
                &securityDescriptor,
                nil
            )
            guard conversionResult != 0, let descriptor = securityDescriptor else {
                let error = GetLastError()
                logger.warning("admin pipe security descriptor creation failed", metadata: ["error": "\(error)"])
                return nil
            }

            let attributes = UnsafeMutablePointer<SECURITY_ATTRIBUTES>.allocate(capacity: 1)
            attributes.initialize(to: SECURITY_ATTRIBUTES(
                nLength: DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size),
                lpSecurityDescriptor: descriptor,
                bInheritHandle: FALSE
            ))
            return (attributes, descriptor)
        }
    }
}
#endif
