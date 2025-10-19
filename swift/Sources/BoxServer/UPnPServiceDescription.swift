#if !os(Windows)
import Foundation

struct UPnPServiceDescription: Sendable, Equatable {
    let serviceType: String
    let controlURL: URL
}
#endif
