import Foundation

enum BoxAdminParsedCommand {
    case status
    case ping
    case logTarget(String)
    case reloadConfig(String?)
    case stats
    case locate(UUID)
    case natProbe(String?)
    case invalid(String)
    case unknown(String)
}
