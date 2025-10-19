import Foundation

struct ConnectivitySnapshot: Sendable {
    var globalIPv6Addresses: [String]
    var detectionErrorDescription: String?

    var hasGlobalIPv6: Bool {
        !globalIPv6Addresses.isEmpty
    }
}
