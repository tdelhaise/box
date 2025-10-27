
import Foundation
import BoxCore

internal func adminResponse(_ payload: [String: Any]) -> String {
    do {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? ""
    } catch {
        return "{\"status\":\"error\",\"message\":\"json-serialization-error\"}"
    }
}

internal func adminLocationRecordPayload(from record: LocationServiceNodeRecord) -> [String: Any] {
    let payload: [String: Any] = [
        "status": "ok",
        "record": record.toDictionary()
    ]
    return payload
}

internal func adminLocationUserPayload(userUUID: UUID, records: [LocationServiceNodeRecord]) -> [String: Any] {
    let payload: [String: Any] = [
        "status": "ok",
        "user": [
            "userUUID": userUUID.uuidString,
            "nodeUUIDs": records.map { $0.nodeUUID.uuidString },
            "records": records.map { $0.toDictionary() }
        ]
    ]
    return payload
}

extension LocationServiceNodeRecord {
    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "userUUID": userUUID.uuidString,
            "nodeUUID": nodeUUID.uuidString,
            "addresses": addresses.map { $0.toDictionary() },
            "online": online,
            "since": since,
            "lastSeen": lastSeen,
            "connectivity": connectivity.toDictionary()
        ]
        if let nodePublicKey {
            dict["nodePublicKey"] = nodePublicKey
        }
        if let tags {
            dict["tags"] = tags
        }
        return dict
    }
}

extension LocationServiceNodeRecord.Address {
    func toDictionary() -> [String: Any] {
        [
            "ip": ip,
            "port": port,
            "scope": scope.rawValue,
            "source": source.rawValue
        ]
    }
}

extension LocationServiceNodeRecord.Connectivity {
    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "hasGlobalIPv6": hasGlobalIPv6,
            "globalIPv6": globalIPv6,
            "portMapping": portMapping.toDictionary()
        ]
        if let ipv6ProbeError {
            dict["ipv6ProbeError"] = ipv6ProbeError
        }
        return dict
    }
}

extension LocationServiceNodeRecord.Connectivity.PortMapping {
    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "enabled": enabled,
            "origin": origin
        ]
        if let externalIPv4 {
            dict["externalIPv4"] = externalIPv4
        }
        if let externalPort {
            dict["externalPort"] = externalPort
        }
        if let peer {
            dict["peer"] = peer.toDictionary()
        }
        if let status {
            dict["status"] = status
        }
        if let error {
            dict["error"] = error
        }
        if let errorCode {
            dict["errorCode"] = errorCode
        }
        if let reachability {
            dict["reachability"] = reachability.toDictionary()
        }
        return dict
    }
}

extension LocationServiceNodeRecord.Connectivity.PortMapping.Peer {
    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "status": status
        ]
        if let lifetimeSeconds {
            dict["lifetimeSeconds"] = lifetimeSeconds
        }
        if let lastUpdated {
            dict["lastUpdated"] = lastUpdated
        }
        if let error {
            dict["error"] = error
        }
        return dict
    }
}

extension LocationServiceNodeRecord.Connectivity.PortMapping.Reachability {
    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "status": status
        ]
        if let lastChecked {
            dict["lastChecked"] = lastChecked
        }
        if let roundTripMillis {
            dict["roundTripMillis"] = roundTripMillis
        }
        if let error {
            dict["error"] = error
        }
        return dict
    }
}
