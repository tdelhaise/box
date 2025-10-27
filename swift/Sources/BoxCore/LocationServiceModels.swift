import Foundation

/// Describes a node record exposed by the embedded Location Service.
public struct LocationServiceNodeRecord: Codable, Sendable {
    /// Represents a reachable socket address advertised to peers.
    public struct Address: Codable, Hashable, Sendable {
        /// Indicates the reachability scope of the address.
        public enum Scope: String, Codable, Sendable {
            case global
            case lan
            case loopback
        }

        /// Identifies how the address was obtained.
        public enum Source: String, Codable, Sendable {
            case probe
            case config
            case manual
        }

        /// Textual IP representation (IPv6 or IPv4).
        public var ip: String
        /// UDP port associated with the address.
        public var port: UInt16
        /// Reachability scope (global, LAN, loopback).
        public var scope: Scope
        /// Origin of the address (probe/config/manual).
        public var source: Source

        /// Creates a new address record ready for publication.
        /// - Parameters:
        ///   - ip: Textual IP address.
        ///   - port: UDP port associated with the record.
        ///   - scope: Reachability scope.
        ///   - source: Source describing how the address was learned.
        public init(ip: String, port: UInt16, scope: Scope, source: Source) {
            self.ip = ip
            self.port = port
            self.scope = scope
            self.source = source
        }
    }

    /// Captures the connectivity snapshot associated with a node.
    public struct Connectivity: Codable, Sendable {
        /// Summarises the current port-mapping preference.
        public struct PortMapping: Codable, Sendable {
            /// Represents the outcome of an auxiliary PCP PEER request.
            public struct Peer: Codable, Sendable {
                /// Human-readable status (`ok`, `error`, `skipped`).
                public var status: String
                /// Lease duration returned by the gateway (seconds).
                public var lifetimeSeconds: UInt32?
                /// Timestamp of the last update (milliseconds since epoch).
                public var lastUpdated: UInt64?
                /// Optional error description when the request fails.
                public var error: String?

                /// Creates a new peer mapping summary.
                /// - Parameters:
                ///   - status: Status string reported by the coordinator.
                ///   - lifetimeSeconds: Lease duration reported by the gateway.
                ///   - lastUpdated: Millisecond timestamp indicating when the status was observed.
                ///   - error: Optional error description.
                public init(
                    status: String,
                    lifetimeSeconds: UInt32? = nil,
                    lastUpdated: UInt64? = nil,
                    error: String? = nil
                ) {
                    self.status = status
                    self.lifetimeSeconds = lifetimeSeconds
                    self.lastUpdated = lastUpdated
                    self.error = error
                }

                private enum CodingKeys: String, CodingKey {
                    case status
                    case lifetimeSeconds = "lifetime_seconds"
                    case lastUpdated = "last_updated"
                    case error
                }
            }

            /// Describes the reachability verification snapshot for the advertised external endpoint.
            public struct Reachability: Codable, Sendable {
                /// Status string (`ok`, `error`, `skipped`, etc.).
                public var status: String
                /// Millisecond timestamp of the last verification, when available.
                public var lastChecked: UInt64?
                /// Round-trip time reported by the probe, expressed in milliseconds.
                public var roundTripMillis: UInt32?
                /// Optional error description when the probe fails.
                public var error: String?

                /// Creates a reachability snapshot description.
                /// - Parameters:
                ///   - status: Status string reported by the coordinator.
                ///   - lastChecked: Millisecond timestamp for the last probe execution.
                ///   - roundTripMillis: Observed round-trip time.
                ///   - error: Optional error description.
                public init(
                    status: String,
                    lastChecked: UInt64? = nil,
                    roundTripMillis: UInt32? = nil,
                    error: String? = nil
                ) {
                    self.status = status
                    self.lastChecked = lastChecked
                    self.roundTripMillis = roundTripMillis
                    self.error = error
                }

                private enum CodingKeys: String, CodingKey {
                    case status
                    case lastChecked = "last_checked"
                    case roundTripMillis = "round_trip_ms"
                    case error
                }
            }

            /// Indicates whether port mapping has been requested.
            public var enabled: Bool
            /// Describes where the preference originates (`default`, `cli`, `config`).
            public var origin: String
            /// External IPv4 reported by the mapping backend.
            public var externalIPv4: String?
            /// External UDP port reported by the mapping backend.
            public var externalPort: UInt16?
            /// Optional PCP PEER status.
            public var peer: Peer?
            /// Optional status string for the mapping backend.
            public var status: String?
            /// Optional error description when the mapping attempt fails.
            public var error: String?
            /// Optional structured error code emitted by the coordinator.
            public var errorCode: String?
            /// Optional reachability probe outcome.
            public var reachability: Reachability?

            /// Creates a new summary for the port-mapping state.
            /// - Parameters:
            ///   - enabled: Whether port mapping is currently requested.
            ///   - origin: Human-readable origin string.
            ///   - externalIPv4: External IPv4 address reported by the gateway.
            ///   - externalPort: External UDP port reported by the gateway.
            ///   - peer: Optional PCP PEER status.
            ///   - status: Optional backend status string.
            ///   - error: Optional error description.
            ///   - errorCode: Optional structured error code.
            ///   - reachability: Optional reachability probe snapshot.
            public init(
                enabled: Bool,
                origin: String,
                externalIPv4: String? = nil,
                externalPort: UInt16? = nil,
                peer: Peer? = nil,
                status: String? = nil,
                error: String? = nil,
                errorCode: String? = nil,
                reachability: Reachability? = nil
            ) {
                self.enabled = enabled
                self.origin = origin
                self.externalIPv4 = externalIPv4
                self.externalPort = externalPort
                self.peer = peer
                self.status = status
                self.error = error
                self.errorCode = errorCode
                self.reachability = reachability
            }

            private enum CodingKeys: String, CodingKey {
                case enabled
                case origin
                case externalIPv4 = "external_ipv4"
                case externalPort = "external_port"
                case peer
                case status
                case error
                case errorCode = "error_code"
                case reachability
            }
        }

        /// Indicates if the host currently owns at least one global IPv6 address.
        public var hasGlobalIPv6: Bool
        /// List of IPv6 addresses detected on the host.
        public var globalIPv6: [String]
        /// Optional error when the IPv6 probe fails.
        public var ipv6ProbeError: String?
        /// Port-mapping state requested by the operator.
        public var portMapping: PortMapping

        /// Creates a new connectivity snapshot.
        /// - Parameters:
        ///   - hasGlobalIPv6: Indicates whether a global IPv6 address was detected.
        ///   - globalIPv6: List of detected global IPv6 addresses.
        ///   - ipv6ProbeError: Optional descriptive error when detection fails.
        ///   - portMapping: Summary of the port-mapping preference.
        public init(
            hasGlobalIPv6: Bool,
            globalIPv6: [String],
            ipv6ProbeError: String?,
            portMapping: PortMapping
        ) {
            self.hasGlobalIPv6 = hasGlobalIPv6
            self.globalIPv6 = globalIPv6
            self.ipv6ProbeError = ipv6ProbeError
            self.portMapping = portMapping
        }

        private enum CodingKeys: String, CodingKey {
            case hasGlobalIPv6 = "has_global_ipv6"
            case globalIPv6 = "global_ipv6"
            case ipv6ProbeError = "ipv6_probe_error"
            case portMapping = "port_mapping"
        }
    }

    /// UUID describing the user this node serves.
    public var userUUID: UUID
    /// UUID describing the node instance.
    public var nodeUUID: UUID
    /// Reachable addresses published for this node.
    public var addresses: [Address]
    /// Optional base64/hex representation of the node public key.
    public var nodePublicKey: String?
    /// Indicates whether the node is currently online.
    public var online: Bool
    /// Timestamp (ms since epoch) when the node came online.
    public var since: UInt64
    /// Timestamp (ms since epoch) for the last heartbeat/update.
    public var lastSeen: UInt64
    /// Connectivity snapshot attached to the record.
    public var connectivity: Connectivity
    /// Optional free-form tags for consumers.
    public var tags: [String: String]?

    /// Creates a new Location Service node record.
    /// - Parameters match the stored properties of the struct.
    public init(
        userUUID: UUID,
        nodeUUID: UUID,
        addresses: [Address],
        nodePublicKey: String?,
        online: Bool,
        since: UInt64,
        lastSeen: UInt64,
        connectivity: Connectivity,
        tags: [String: String]? = nil
    ) {
        self.userUUID = userUUID
        self.nodeUUID = nodeUUID
        self.addresses = addresses
        self.nodePublicKey = nodePublicKey
        self.online = online
        self.since = since
        self.lastSeen = lastSeen
        self.connectivity = connectivity
        self.tags = tags
    }

    private enum CodingKeys: String, CodingKey {
        case userUUID = "user_uuid"
        case nodeUUID = "node_uuid"
        case addresses
        case nodePublicKey = "node_public_key"
        case online
        case since
        case lastSeen = "last_seen"
        case connectivity
        case tags
    }
}

public extension LocationServiceNodeRecord {
    /// Builds a Location Service record from runtime connectivity data.
    /// - Parameters:
    ///   - userUUID: Stable user identifier.
    ///   - nodeUUID: Stable node identifier.
    ///   - port: UDP port advertised to peers.
    ///   - probedGlobalIPv6: IPv6 addresses detected via the runtime probe.
    ///   - ipv6Error: Optional error captured during IPv6 probing.
    ///   - portMappingEnabled: Indicates if port mapping is enabled.
    ///   - portMappingOrigin: Origin of the port mapping preference.
    ///   - additionalAddresses: Supplementary addresses (e.g., configured IPv4/IPv6).
    ///   - online: Whether the node should be flagged as online.
    ///   - since: Optional online timestamp (milliseconds since epoch). Defaults to now.
    ///   - lastSeen: Optional heartbeat timestamp (milliseconds since epoch). Defaults to now.
    ///   - nodePublicKey: Optional textual representation of the node public key.
    ///   - tags: Optional extra metadata.
    /// - Returns: A fully populated `LocationServiceNodeRecord`.
    static func make(
        userUUID: UUID,
        nodeUUID: UUID,
        port: UInt16,
        probedGlobalIPv6: [String],
        ipv6Error: String?,
        portMappingEnabled: Bool,
        portMappingOrigin: BoxRuntimeOptions.PortMappingOrigin,
        additionalAddresses: [Address] = [],
        portMappingExternalIPv4: String? = nil,
        portMappingExternalPort: UInt16? = nil,
        portMappingPeer: Connectivity.PortMapping.Peer? = nil,
        portMappingStatus: String? = nil,
        portMappingError: String? = nil,
        portMappingErrorCode: String? = nil,
        portMappingReachability: Connectivity.PortMapping.Reachability? = nil,
        online: Bool = true,
        since: UInt64? = nil,
        lastSeen: UInt64? = nil,
        nodePublicKey: String? = nil,
        tags: [String: String]? = nil
    ) -> LocationServiceNodeRecord {
        let timestampNow = UInt64(Date().timeIntervalSince1970 * 1000)
        let resolvedSince = since ?? timestampNow
        let resolvedLastSeen = lastSeen ?? timestampNow

        var addressSet = Set(additionalAddresses)
        for addressString in probedGlobalIPv6 {
            let candidate = Address(ip: addressString, port: port, scope: .global, source: .probe)
            addressSet.insert(candidate)
        }
        let connectivity = Connectivity(
            hasGlobalIPv6: !probedGlobalIPv6.isEmpty,
            globalIPv6: probedGlobalIPv6,
            ipv6ProbeError: ipv6Error,
            portMapping: Connectivity.PortMapping(
                enabled: portMappingEnabled,
                origin: portMappingOrigin.locationServiceValue,
                externalIPv4: portMappingExternalIPv4,
                externalPort: portMappingExternalPort,
                peer: portMappingPeer,
                status: portMappingStatus,
                error: portMappingError,
                errorCode: portMappingErrorCode,
                reachability: portMappingReachability
            )
        )

        return LocationServiceNodeRecord(
            userUUID: userUUID,
            nodeUUID: nodeUUID,
            addresses: Array(addressSet).sorted { lhs, rhs in
                if lhs.scope == rhs.scope {
                    return lhs.ip < rhs.ip
                }
                return lhs.scope.rawValue < rhs.scope.rawValue
            },
            nodePublicKey: nodePublicKey,
            online: online,
            since: resolvedSince,
            lastSeen: resolvedLastSeen,
            connectivity: connectivity,
            tags: tags
        )
    }
}

public extension BoxRuntimeOptions.PortMappingOrigin {
    /// Returns the string representation expected by Location Service consumers.
    var locationServiceValue: String {
        switch self {
        case .default:
            return "default"
        case .cliFlag:
            return "cli"
        case .configuration:
            return "config"
        }
    }
}

/// Captures the association between a user and the nodes currently online on their behalf.
public struct LocationServiceUserRecord: Codable, Sendable {
    /// Unique identifier of the user.
    public var userUUID: UUID
    /// Identifiers of nodes belonging to the user.
    public var nodeUUIDs: [UUID]
    /// Timestamp (ms since epoch) describing when the record was last updated.
    public var updatedAt: UInt64

    /// Creates a new user record.
    /// - Parameters match the stored properties of the struct.
    public init(userUUID: UUID, nodeUUIDs: [UUID], updatedAt: UInt64) {
        self.userUUID = userUUID
        self.nodeUUIDs = nodeUUIDs
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case userUUID = "user_uuid"
        case nodeUUIDs = "node_uuids"
        case updatedAt = "updated_at"
    }
}

public extension LocationServiceUserRecord {
    /// Builds a deterministic user record from the supplied node list.
    /// - Parameters:
    ///   - userUUID: Identifier of the user.
    ///   - nodeUUIDs: Node identifiers associated to the user.
    ///   - updatedAt: Optional timestamp override (milliseconds since epoch).
    /// - Returns: A normalised user record suitable for persistence.
    static func make(userUUID: UUID, nodeUUIDs: [UUID], updatedAt: UInt64? = nil) -> LocationServiceUserRecord {
        let timestamp = updatedAt ?? UInt64(Date().timeIntervalSince1970 * 1000)
        let deduplicated = Array(Set(nodeUUIDs)).sorted { $0.uuidString < $1.uuidString }
        return LocationServiceUserRecord(userUUID: userUUID, nodeUUIDs: deduplicated, updatedAt: timestamp)
    }
}
