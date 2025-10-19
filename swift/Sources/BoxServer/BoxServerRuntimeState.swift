import BoxCore
import Foundation
import Logging

struct BoxServerRuntimeState: Sendable {
    var configurationPath: String?
    var configuration: BoxConfiguration?
    var logLevel: Logger.Level
    var logLevelOrigin: BoxRuntimeOptions.LogLevelOrigin
    var logTarget: BoxLogTarget
    var logTargetOrigin: BoxRuntimeOptions.LogTargetOrigin
    var adminChannelEnabled: Bool
    var port: UInt16
    var portOrigin: BoxRuntimeOptions.PortOrigin
    var transport: String?
    var nodeIdentifier: UUID
    var userIdentifier: UUID
    var queueRootPath: String?
    var reloadCount: Int
    var lastReloadTimestamp: Date?
    var lastReloadStatus: String
    var lastReloadError: String?
    var hasGlobalIPv6: Bool
    var globalIPv6Addresses: [String]
    var ipv6DetectionError: String?
    var portMappingRequested: Bool
    var portMappingOrigin: BoxRuntimeOptions.PortMappingOrigin
    var portMappingBackend: String?
    var portMappingExternalPort: UInt16?
    var portMappingGateway: String?
    var portMappingService: String?
    var portMappingLeaseSeconds: UInt32?
    var portMappingLastRefresh: Date?
    var portMappingExternalIPv4: String?
    var portMappingPeerStatus: String?
    var portMappingPeerLifetime: UInt32?
    var portMappingPeerLastUpdate: Date?
    var portMappingPeerError: String?
    var manualExternalAddress: String?
    var manualExternalPort: UInt16?
    var manualExternalOrigin: BoxRuntimeOptions.ExternalAddressOrigin
    var onlineSince: Date
    var lastPresenceUpdate: Date?
}
