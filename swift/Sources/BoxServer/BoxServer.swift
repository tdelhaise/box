import BoxCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(SystemConfiguration)
import SystemConfiguration
#endif
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

#if os(Linux)
import Glibc
#elseif os(Windows)
import WinSDK
#else
import Darwin
#endif

public enum BoxServer {
    public static func run(with options: BoxRuntimeOptions) async throws {
        let controller = BoxServerRuntimeController(options: options)
        do {
            try await controller.start()
        } catch is CancellationError {
            await controller.stop()
        } catch {
            await controller.stop()
            throw error
        }
    }
}
