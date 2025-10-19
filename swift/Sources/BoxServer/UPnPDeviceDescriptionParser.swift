#if !os(Windows)
import Foundation

final class UPnPDeviceDescriptionParser {
    init(baseURL: URL) {}
    func parse(data: Data) throws -> [UPnPServiceDescription] {
        return []
    }
}
#endif