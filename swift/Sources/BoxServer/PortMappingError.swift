import Foundation

enum PortMappingError: Error, CustomStringConvertible {
    case socket(Int32)
    case httpError
    case soapFault(code: Int, payload: Data)
    case network(String)
    case natpmp(String)
    case pcp(String)
    case backend(String)

    var description: String {
        switch self {
        case .socket(let code):
            return "socket-error(\(code))"
        case .httpError:
            return "http-error"
        case .soapFault(let code, _):
            return "soap-fault(\(code))"
        case .network(let message):
            return "network-error(\(message))"
        case .natpmp(let message):
            return "natpmp-error(\(message))"
        case .pcp(let message):
            return "pcp-error(\(message))"
        case .backend(let message):
            return "backend-error(\(message))"
        }
    }
}
