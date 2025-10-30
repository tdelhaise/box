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

#if os(Linux)
import Glibc
#elseif os(Windows)
import WinSDK
#else
import Darwin
#endif

final class PortMappingCoordinator: @unchecked Sendable {
    struct MappingSnapshot: Sendable {
        let status: String
        let backend: String?
        let externalPort: UInt16?
        let gateway: String?
        let service: String?
        let lifetime: UInt32?
        let refreshedAt: Date?
        let externalIPv4: String?
        let peerStatus: String?
        let peerLifetime: UInt32?
        let peerLastUpdate: Date?
        let peerError: String?
        let error: String?
        let errorCode: String?
        let reachabilityStatus: String?
        let reachabilityCheckedAt: Date?
        let reachabilityRoundTripMillis: Int?
        let reachabilityError: String?
    }

    struct ReachabilitySnapshot: Sendable {
        let status: String
        let lastChecked: Date
        let roundTripMillis: Int?
        let error: String?
    }

    struct ProbeReport: Sendable {
        let backend: String
        let status: String
        let externalPort: UInt16?
        let externalIPv4: String?
        let lifetime: UInt32?
        let gateway: String?
        let service: String?
        let error: String?
        let errorCode: String?
        let peerStatus: String?
        let peerLifetime: UInt32?
        let peerLastUpdate: Date?
        let peerError: String?

        init(
            backend: String,
            status: String,
            externalPort: UInt16? = nil,
            externalIPv4: String? = nil,
            lifetime: UInt32? = nil,
            gateway: String? = nil,
            service: String? = nil,
            error: String? = nil,
            errorCode: String? = nil,
            peerStatus: String? = nil,
            peerLifetime: UInt32? = nil,
            peerLastUpdate: Date? = nil,
            peerError: String? = nil
        ) {
            self.backend = backend
            self.status = status
            self.externalPort = externalPort
            self.externalIPv4 = externalIPv4
            self.lifetime = lifetime
            self.gateway = gateway
            self.service = service
            self.error = error
            self.errorCode = errorCode
            self.peerStatus = peerStatus
            self.peerLifetime = peerLifetime
            self.peerLastUpdate = peerLastUpdate
            self.peerError = peerError
        }

        func toDictionary() -> [String: Any] {
            var payload: [String: Any] = [
                "backend": backend,
                "status": status
            ]
            if let externalPort {
                payload["externalPort"] = Int(externalPort)
            }
            if let externalIPv4 {
                payload["externalIPv4"] = externalIPv4
            }
            if let lifetime {
                payload["leaseSeconds"] = lifetime
            }
            if let gateway {
                payload["gateway"] = gateway
            }
            if let service {
                payload["service"] = service
            }
            if let error {
                payload["error"] = error
            }
            if let errorCode {
                payload["errorCode"] = errorCode
            }
            if let peerStatus {
                payload["peerStatus"] = peerStatus
            }
            if let peerLifetime {
                payload["peerLifetime"] = peerLifetime
            }
            if let peerLastUpdate {
                payload["peerLastUpdated"] = iso8601String(peerLastUpdate)
            }
            if let peerError {
                payload["peerError"] = peerError
            }
            return payload
        }
    }

    private struct PCPContext: Sendable {
        var gateway: String
        var clientAddress: [UInt8]
        var nonce: [UInt8]
        var protocolValue: UInt8
        var internalPort: UInt16
        var suggestedExternalIP: [UInt8]
        var externalIPv4: String?
        var peer: PeerState?

        struct PeerState: Sendable {
            var nonce: [UInt8]
            var remotePeerIP: [UInt8]
            var remotePeerPort: UInt16
            var status: String
            var lifetime: UInt32?
            var lastUpdated: Date
            var error: String?
            var externalPort: UInt16
        }
    }

    private enum Backend: Sendable {
        case upnp(service: UPnPServiceDescription, internalClient: String, externalIPv4: String?)
        case natpmp(gateway: String, externalIPv4: String?)
        case pcp(context: PCPContext)

        var identifier: String {
            switch self {
            case .upnp: return "upnp"
            case .natpmp: return "natpmp"
            case .pcp: return "pcp"
            }
        }

        var gateway: String? {
            switch self {
            case .upnp: return nil
            case .natpmp(let gateway, _): return gateway
            case .pcp(let context): return context.gateway
            }
        }

        var serviceDescription: String? {
            switch self {
            case .upnp(let service, _, _): return service.serviceType
            case .natpmp: return nil
            case .pcp: return nil
            }
        }

        var externalIPv4: String? {
            switch self {
            case .upnp(_, _, let externalIPv4): return externalIPv4
            case .natpmp(_, let externalIPv4): return externalIPv4
            case .pcp(let context): return context.externalIPv4
            }
        }
    }

    private struct MappingHandle: Sendable {
        let backend: Backend
        let externalPort: UInt16
        let lifetime: UInt32
    }

    private let logger: Logger
    private let port: UInt16
    private let origin: BoxRuntimeOptions.PortMappingOrigin
    private let nodeIdentifier: UUID
    private let userIdentifier: UUID
    private let leaseDuration: UInt32 = 3_600
    private var task: Task<Void, Never>?
    private let state = NIOLockedValueBox<MappingHandle?>(nil)
    private let reachabilityState = NIOLockedValueBox<ReachabilitySnapshot?>(nil)
    private let onStateChange: @Sendable (MappingSnapshot?) -> Void

    init(
        logger: Logger,
        port: UInt16,
        origin: BoxRuntimeOptions.PortMappingOrigin,
        nodeIdentifier: UUID,
        userIdentifier: UUID,
        onStateChange: @escaping @Sendable (MappingSnapshot?) -> Void
    ) {
        self.logger = logger
        self.port = port
        self.origin = origin
        self.nodeIdentifier = nodeIdentifier
        self.userIdentifier = userIdentifier
        self.onStateChange = onStateChange
    }

    func start() {
#if os(Windows)
        logger.info("port mapping not available on Windows yet", metadata: ["origin": "\(origin)"])
#else
        guard task == nil else { return }
        logger.info(
            "port mapping requested",
            metadata: [
                "port": "\(port)",
                "origin": "\(origin)"
            ]
        )
        task = Task.detached { [weak self] in
            await self?.run()
        }
#endif
    }

    func stop() {
#if !os(Windows)
        task?.cancel()
        task = nil
#endif
        if let handle = state.withLockedValue({ $0 }) {
            Task.detached { [weak self] in
                guard let self else { return }
                await self.removeMapping(handle)
                self.publishStatus(
                    status: "stopped",
                    backend: handle.backend.identifier,
                    gateway: handle.backend.gateway,
                    service: handle.backend.serviceDescription,
                    externalIPv4: handle.backend.externalIPv4,
                    externalPort: handle.externalPort,
                    lifetime: handle.lifetime,
                    error: nil
                )
            }
        } else {
            publishStatus(
                status: "stopped",
                backend: nil,
                gateway: nil,
                service: nil,
                externalIPv4: nil,
                externalPort: nil,
                lifetime: nil,
                error: nil
            )
        }
        logger.debug("port mapping coordinator stopped")
    }

#if !os(Windows)
    private func run() async {
        do {
            guard let localAddress = try firstNonLoopbackIPv4Address() else {
                logger.info("port mapping skipped: no non-loopback IPv4 address detected")
                publishStatus(
                    status: "error",
                    backend: nil,
                    gateway: nil,
                    service: nil,
                    externalIPv4: nil,
                    externalPort: nil,
                    lifetime: nil,
                    error: PortMappingError.backend("ipv4-not-detected")
                )
                return
            }
            try Task.checkCancellation()

            do {
                let handle = try await attemptUPnP(localAddress: localAddress)
                await maintainMapping(initial: handle)
                return
            } catch {
                if Task.isCancelled { return }
                logger.debug("UPnP mapping attempt failed", metadata: ["error": .string("\(error)")])
                publishStatus(
                    status: "error",
                    backend: "upnp",
                    gateway: nil,
                    service: nil,
                    externalIPv4: nil,
                    externalPort: nil,
                    lifetime: nil,
                    error: error
                )
            }

            do {
                let handle = try attemptPCP(localAddress: localAddress, gatewayOverride: nil)
                await maintainMapping(initial: handle)
                return
            } catch {
                if Task.isCancelled { return }
                logger.debug("PCP mapping attempt failed", metadata: ["error": .string("\(error)")])
                publishStatus(
                    status: "error",
                    backend: "pcp",
                    gateway: nil,
                    service: nil,
                    externalIPv4: nil,
                    externalPort: nil,
                    lifetime: nil,
                    error: error
                )
            }

            do {
                let handle = try attemptNATPMP(gatewayOverride: nil)
                await maintainMapping(initial: handle)
                return
            } catch {
                if Task.isCancelled { return }
                logger.debug("NAT-PMP mapping attempt failed", metadata: ["error": .string("\(error)")])
                publishStatus(
                    status: "error",
                    backend: "natpmp",
                    gateway: nil,
                    service: nil,
                    externalIPv4: nil,
                    externalPort: nil,
                    lifetime: nil,
                    error: error
                )
            }

            logger.info("port mapping skipped: no supported gateway found")
            publishStatus(
                status: "skipped",
                backend: nil,
                gateway: nil,
                service: nil,
                externalIPv4: nil,
                externalPort: nil,
                lifetime: nil,
                error: nil
            )
        } catch {
            if Task.isCancelled { return }
            logger.warning("port mapping aborted", metadata: ["error": .string("\(error)")])
            publishStatus(
                status: "error",
                backend: nil,
                gateway: nil,
                service: nil,
                externalIPv4: nil,
                externalPort: nil,
                lifetime: nil,
                error: error
            )
        }
    }

    func probe(gatewayOverride: String?) async -> [ProbeReport] {
        if let skip = getenv("BOX_SKIP_NAT_PROBE"), skip[0] != 0 {
            return []
        }
        var reports: [ProbeReport] = []
        do {
            guard let localAddress = try firstNonLoopbackIPv4Address() else {
                let failure = ProbeReport(backend: "upnp", status: "skipped", externalPort: nil, externalIPv4: nil, lifetime: nil, gateway: nil, service: nil, error: "ipv4-not-detected", errorCode: "preflight:ipv4-not-detected")
                reports.append(failure)
                reports.append(ProbeReport(backend: "pcp", status: "skipped", externalPort: nil, externalIPv4: nil, lifetime: nil, gateway: nil, service: nil, error: "ipv4-not-detected", errorCode: "preflight:ipv4-not-detected"))
                reports.append(ProbeReport(backend: "natpmp", status: "skipped", externalPort: nil, externalIPv4: nil, lifetime: nil, gateway: nil, service: nil, error: "ipv4-not-detected", errorCode: "preflight:ipv4-not-detected"))
                return reports
            }

            do {
                let handle = try await attemptUPnP(localAddress: localAddress)
                await removeMapping(handle)
                reports.append(
                    ProbeReport(
                        backend: "upnp",
                        status: "ok",
                        externalPort: handle.externalPort,
                        externalIPv4: handle.backend.externalIPv4,
                        lifetime: handle.lifetime,
                        gateway: handle.backend.gateway,
                        service: handle.backend.serviceDescription,
                        error: nil,
                        errorCode: nil
                    )
                )
            } catch {
                let telemetry = errorTelemetry(for: error)
                reports.append(
                    ProbeReport(
                        backend: "upnp",
                        status: "error",
                        externalPort: nil,
                        externalIPv4: nil,
                        lifetime: nil,
                        gateway: nil,
                        service: nil,
                        error: telemetry.message,
                        errorCode: telemetry.code
                    )
                )
            }

            do {
                let handle = try attemptPCP(localAddress: localAddress, gatewayOverride: gatewayOverride)
                var peerStatus: String?
                var peerLifetime: UInt32?
                var peerLastUpdate: Date?
                var peerError: String?
                if case .pcp(let context) = handle.backend, let peer = context.peer {
                    peerStatus = peer.status
                    peerLifetime = peer.lifetime
                    peerLastUpdate = peer.lastUpdated
                    peerError = peer.error
                }
                await removeMapping(handle)
                reports.append(
                    ProbeReport(
                        backend: "pcp",
                        status: "ok",
                        externalPort: handle.externalPort,
                        externalIPv4: handle.backend.externalIPv4,
                        lifetime: handle.lifetime,
                        gateway: handle.backend.gateway,
                        service: handle.backend.serviceDescription,
                        error: nil,
                        errorCode: nil,
                        peerStatus: peerStatus,
                        peerLifetime: peerLifetime,
                        peerLastUpdate: peerLastUpdate,
                        peerError: peerError
                    )
                )
            } catch {
                let telemetry = errorTelemetry(for: error)
                reports.append(
                    ProbeReport(
                        backend: "pcp",
                        status: "error",
                        externalPort: nil,
                        externalIPv4: nil,
                        lifetime: nil,
                        gateway: gatewayOverride ?? defaultGatewayIPv4(),
                        service: nil,
                        error: telemetry.message,
                        errorCode: telemetry.code
                    )
                )
            }

            do {
                let handle = try attemptNATPMP(gatewayOverride: gatewayOverride)
                await removeMapping(handle)
                reports.append(
                    ProbeReport(
                        backend: "natpmp",
                        status: "ok",
                        externalPort: handle.externalPort,
                        externalIPv4: handle.backend.externalIPv4,
                        lifetime: handle.lifetime,
                        gateway: handle.backend.gateway,
                        service: handle.backend.serviceDescription,
                        error: nil,
                        errorCode: nil
                    )
                )
            } catch {
                let telemetry = errorTelemetry(for: error)
                reports.append(
                    ProbeReport(
                        backend: "natpmp",
                        status: "error",
                        externalPort: nil,
                        externalIPv4: nil,
                        lifetime: nil,
                        gateway: gatewayOverride ?? defaultGatewayIPv4(),
                        service: nil,
                        error: telemetry.message,
                        errorCode: telemetry.code
                    )
                )
            }
        } catch {
            let telemetry = errorTelemetry(for: error)
            reports.append(
                ProbeReport(
                    backend: "upnp",
                    status: "error",
                    externalPort: nil,
                    externalIPv4: nil,
                    lifetime: nil,
                    gateway: nil,
                    service: nil,
                    error: telemetry.message,
                    errorCode: telemetry.code
                )
            )
            reports.append(
                ProbeReport(
                    backend: "pcp",
                    status: "error",
                    externalPort: nil,
                    externalIPv4: nil,
                    lifetime: nil,
                    gateway: gatewayOverride ?? defaultGatewayIPv4(),
                    service: nil,
                    error: telemetry.message,
                    errorCode: telemetry.code
                )
            )
            reports.append(
                ProbeReport(
                    backend: "natpmp",
                    status: "error",
                    externalPort: nil,
                    externalIPv4: nil,
                    lifetime: nil,
                    gateway: gatewayOverride ?? defaultGatewayIPv4(),
                    service: nil,
                    error: telemetry.message,
                    errorCode: telemetry.code
                )
            )
        }
        return reports
    }

    private func errorTelemetry(for error: Error) -> (message: String, code: String) {
        if let mappingError = error as? PortMappingError {
            switch mappingError {
            case .socket(let code):
                return (mappingError.description, "socket:\(code)")
            case .httpError:
                return (mappingError.description, "http")
            case .soapFault(let code, _):
                return (mappingError.description, "soap:\(code)")
            case .network(let message):
                return ("network-error(\(message))", "network:\(message)")
            case .natpmp(let message):
                return ("natpmp-error(\(message))", "natpmp:\(message)")
            case .pcp(let message):
                return ("pcp-error(\(message))", "pcp:\(message)")
            case .backend(let message):
                return ("backend-error(\(message))", "backend:\(message)")
            }
        }
        let nsError = error as NSError
        let code = "\(nsError.domain)#\(nsError.code)"
        return ("\(error)", code)
    }

    private func publishStatus(
        status: String,
        backend: String?,
        gateway: String?,
        service: String?,
        externalIPv4: String?,
        externalPort: UInt16?,
        lifetime: UInt32?,
        error: Error?
    ) {
        let telemetry = error.map { errorTelemetry(for: $0) }
        reachabilityState.withLockedValue { $0 = nil }
        state.withLockedValue { $0 = nil }
        let snapshot = MappingSnapshot(
            status: status,
            backend: backend,
            externalPort: externalPort,
            gateway: gateway,
            service: service,
            lifetime: lifetime,
            refreshedAt: Date(),
            externalIPv4: externalIPv4,
            peerStatus: nil,
            peerLifetime: nil,
            peerLastUpdate: nil,
            peerError: nil,
            error: telemetry?.message,
            errorCode: telemetry?.code,
            reachabilityStatus: nil,
            reachabilityCheckedAt: nil,
            reachabilityRoundTripMillis: nil,
            reachabilityError: nil
        )
        onStateChange(snapshot)
    }

    private func buildSnapshot(handle: MappingHandle, status: String, error: Error?) -> MappingSnapshot {
        let telemetry = error.map { errorTelemetry(for: $0) }
        var peerStatus: String?
        var peerLifetime: UInt32?
        var peerLastUpdate: Date?
        var peerError: String?
        if case .pcp(let context) = handle.backend, let peer = context.peer {
            peerStatus = peer.status
            peerLifetime = peer.lifetime
            peerLastUpdate = peer.lastUpdated
            peerError = peer.error
        }
        let reachability = reachabilityState.withLockedValue { $0 }
        return MappingSnapshot(
            status: status,
            backend: handle.backend.identifier,
            externalPort: handle.externalPort,
            gateway: handle.backend.gateway,
            service: handle.backend.serviceDescription,
            lifetime: handle.lifetime,
            refreshedAt: Date(),
            externalIPv4: handle.backend.externalIPv4,
            peerStatus: peerStatus,
            peerLifetime: peerLifetime,
            peerLastUpdate: peerLastUpdate,
            peerError: peerError,
            error: telemetry?.message,
            errorCode: telemetry?.code,
            reachabilityStatus: reachability?.status,
            reachabilityCheckedAt: reachability?.lastChecked,
            reachabilityRoundTripMillis: reachability?.roundTripMillis,
            reachabilityError: reachability?.error
        )
    }

    private func publish(handle: MappingHandle, status: String = "ok", error: Error? = nil) {
        let snapshot = buildSnapshot(handle: handle, status: status, error: error)
        state.withLockedValue { $0 = handle }
        onStateChange(snapshot)
    }

    private func scheduleReachabilityProbeIfNeeded(for handle: MappingHandle) {
#if os(Windows)
        return
#else
        guard let externalIPv4 = handle.backend.externalIPv4 else { return }
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                let reachability = try self.performReachabilityProbe(externalIPv4: externalIPv4, externalPort: handle.externalPort)
                self.reachabilityState.withLockedValue { $0 = reachability }
                let currentHandle = self.state.withLockedValue { $0 }
                guard let currentHandle else { return }
                let snapshot = self.buildSnapshot(handle: currentHandle, status: "ok", error: nil)
                self.onStateChange(snapshot)
            } catch {
                let failureSnapshot = ReachabilitySnapshot(
                    status: "error",
                    lastChecked: Date(),
                    roundTripMillis: nil,
                    error: "\(error)"
                )
                self.reachabilityState.withLockedValue { $0 = failureSnapshot }
                let currentHandle = self.state.withLockedValue { $0 }
                guard let currentHandle else { return }
                let snapshot = self.buildSnapshot(handle: currentHandle, status: "ok", error: nil)
                self.onStateChange(snapshot)
            }
        }
#endif
    }

    private func maintainMapping(initial handle: MappingHandle) async {
        var currentHandle = handle
        publish(handle: currentHandle)
        scheduleReachabilityProbeIfNeeded(for: currentHandle)
        defer {
            let handleToRemove = currentHandle
            Task { [handleToRemove] in
                await removeMapping(handleToRemove)
            }
        }

        while !Task.isCancelled {
            let refreshSeconds = max(Int(currentHandle.lifetime / 2), 60)
            do {
                try await Task.sleep(nanoseconds: UInt64(refreshSeconds) * 1_000_000_000)
            } catch {
                if Task.isCancelled { return }
            }

            do {
                currentHandle = try await refreshMapping(currentHandle)
                publish(handle: currentHandle)
                scheduleReachabilityProbeIfNeeded(for: currentHandle)
            } catch {
                if Task.isCancelled { return }
                logger.warning("port mapping refresh failed", metadata: ["error": .string("\(error)"), "backend": .string(currentHandle.backend.identifier)])
                publishStatus(
                    status: "error",
                    backend: currentHandle.backend.identifier,
                    gateway: currentHandle.backend.gateway,
                    service: currentHandle.backend.serviceDescription,
                    externalIPv4: currentHandle.backend.externalIPv4,
                    externalPort: currentHandle.externalPort,
                    lifetime: currentHandle.lifetime,
                    error: error
                )
                return
            }
        }
    }

    private func refreshMapping(_ handle: MappingHandle) async throws -> MappingHandle {
        switch handle.backend {
        case .upnp(let service, let client, let externalIPv4):
            try await addPortMapping(service: service, internalClient: client)
            return MappingHandle(backend: .upnp(service: service, internalClient: client, externalIPv4: externalIPv4), externalPort: handle.externalPort, lifetime: handle.lifetime)
        case .natpmp(let gateway, let previousIPv4):
            let result = try performNATPMPMapping(gateway: gateway, lifetime: handle.lifetime)
            let lifetime = result.lifetime > 0 ? result.lifetime : handle.lifetime
            let externalIPv4 = result.externalIPv4 ?? previousIPv4
            return MappingHandle(backend: .natpmp(gateway: gateway, externalIPv4: externalIPv4), externalPort: result.externalPort, lifetime: lifetime)
        case .pcp(var context):
            let result = try performPCPMapping(context: &context, lifetime: handle.lifetime)
            let lifetime = result.lifetime > 0 ? result.lifetime : handle.lifetime
            context.externalIPv4 = result.externalIPv4
            tryPerformPCPPeer(context: &context, externalPort: result.externalPort, lifetime: lifetime)
            return MappingHandle(backend: .pcp(context: context), externalPort: result.externalPort, lifetime: lifetime)
        }
    }

    private func attemptUPnP(localAddress: String) async throws -> MappingHandle {
        guard let service = try await discoverService() else {
            throw PortMappingError.backend("upnp-not-found")
        }
        try Task.checkCancellation()
        try await addPortMapping(service: service, internalClient: localAddress)
        var externalIPv4: String?
        do {
            externalIPv4 = try await fetchExternalIPAddress(service: service)
        } catch {
            logger.debug(
                "unable to resolve UPnP external address",
                metadata: ["error": .string("\(error)")]
            )
        }
        logger.info(
            "UPnP port mapping established",
            metadata: [
                "externalPort": "\(port)",
                "internalClient": .string(localAddress),
                "service": .string(service.serviceType),
                "externalIPv4": .string(externalIPv4 ?? "unknown")
            ]
        )
        return MappingHandle(
            backend: .upnp(service: service, internalClient: localAddress, externalIPv4: externalIPv4),
            externalPort: port,
            lifetime: leaseDuration
        )
    }

    private func attemptPCP(localAddress: String, gatewayOverride: String?) throws -> MappingHandle {
        let gateway: String
        if let override = gatewayOverride, !override.isEmpty {
            gateway = override
        } else if let detected = defaultGatewayIPv4() {
            gateway = detected
        } else {
            throw PortMappingError.backend("pcp-gateway-not-found")
        }
        guard let clientAddress = PortMappingUtilities.ipv4MappedAddress(localAddress) else {
            throw PortMappingError.backend("pcp-ipv4-required")
        }
        var context = PCPContext(
            gateway: gateway,
            clientAddress: clientAddress,
            nonce: PortMappingUtilities.randomNonce(length: 12),
            protocolValue: 17,
            internalPort: port,
            suggestedExternalIP: Array(repeating: 0, count: 16),
            externalIPv4: nil
        )
        let result = try performPCPMapping(context: &context, lifetime: leaseDuration)
        logger.info(
            "PCP port mapping established",
            metadata: [
                "externalPort": "\(result.externalPort)",
                "gateway": .string(gateway)
            ]
        )
        let lifetime = result.lifetime > 0 ? result.lifetime : leaseDuration
        context.externalIPv4 = result.externalIPv4
        tryPerformPCPPeer(context: &context, externalPort: result.externalPort, lifetime: lifetime)
        return MappingHandle(backend: .pcp(context: context), externalPort: result.externalPort, lifetime: lifetime)
    }

    private func attemptNATPMP(gatewayOverride: String?) throws -> MappingHandle {
        let gateway: String
        if let override = gatewayOverride, !override.isEmpty {
            gateway = override
        } else if let detected = defaultGatewayIPv4() {
            gateway = detected
        } else {
            throw PortMappingError.backend("natpmp-gateway-not-found")
        }
        let result = try performNATPMPMapping(gateway: gateway, lifetime: leaseDuration)
        logger.info(
            "NAT-PMP port mapping established",
            metadata: [
                "externalPort": "\(result.externalPort)",
                "gateway": .string(gateway),
                "externalIPv4": .string(result.externalIPv4 ?? "unknown")
            ]
        )
        let lifetime = result.lifetime > 0 ? result.lifetime : leaseDuration
        return MappingHandle(
            backend: .natpmp(gateway: gateway, externalIPv4: result.externalIPv4),
            externalPort: result.externalPort,
            lifetime: lifetime
        )
    }

    private func discoverService() async throws -> UPnPServiceDescription? {
        guard let descriptionURL = try discoverDeviceDescriptionURL() else {
            return nil
        }
        try Task.checkCancellation()
        let data = try await fetchDeviceDescription(from: descriptionURL)
        try Task.checkCancellation()
        let services = try parseServices(from: data, baseURL: descriptionURL)
        return selectPreferredService(from: services)
    }

    private func addPortMapping(service: UPnPServiceDescription, internalClient: String) async throws {
        let arguments = [
            "NewRemoteHost": "",
            "NewExternalPort": "\(port)",
            "NewProtocol": "UDP",
            "NewInternalPort": "\(port)",
            "NewInternalClient": internalClient,
            "NewEnabled": "1",
            "NewPortMappingDescription": "boxd",
            "NewLeaseDuration": "\(leaseDuration)"
        ]
        _ = try await sendSOAPRequest(
            action: "AddPortMapping",
            arguments: arguments,
            service: service
        )
    }

    private func fetchExternalIPAddress(service: UPnPServiceDescription) async throws -> String? {
        let data = try await sendSOAPRequest(
            action: "GetExternalIPAddress",
            arguments: [:],
            service: service
        )
        guard let xml = String(data: data, encoding: .utf8) else {
            return nil
        }
        guard let start = xml.range(of: "<NewExternalIPAddress>"),
              let end = xml.range(of: "</NewExternalIPAddress>", range: start.upperBound..<xml.endIndex) else {
            return nil
        }
        let value = xml[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func removeMapping(_ handle: MappingHandle) async {
        switch handle.backend {
        case .upnp(let service, _, _):
            let arguments = [
                "NewRemoteHost": "",
                "NewExternalPort": "\(handle.externalPort)",
                "NewProtocol": "UDP"
            ]
            do {
                _ = try await sendSOAPRequest(
                    action: "DeletePortMapping",
                    arguments: arguments,
                    service: service
                )
                logger.debug("UPnP port mapping removed", metadata: ["port": "\(handle.externalPort)"])
            } catch {
                logger.debug("unable to remove UPnP port mapping", metadata: ["error": .string("\(error)")])
            }
        case .natpmp(let gateway, _):
            do {
                try performNATPMPDeletion(gateway: gateway, externalPort: handle.externalPort)
                logger.debug("NAT-PMP port mapping removed", metadata: ["port": "\(handle.externalPort)"])
            } catch {
                logger.debug("unable to remove NAT-PMP port mapping", metadata: ["error": .string("\(error)")])
            }
        case .pcp(var context):
            if let peer = context.peer, peer.status == "ok" {
                do {
                    try performPCPPeerDeletion(context: &context)
                    logger.debug("PCP peer mapping removed", metadata: ["port": "\(handle.externalPort)"])
                } catch {
                    logger.debug("unable to remove PCP peer mapping", metadata: ["error": .string("\(error)")])
                }
            }
            do {
                try performPCPDeletion(context: &context)
                logger.debug("PCP port mapping removed", metadata: ["port": "\(handle.externalPort)"])
            } catch {
                logger.debug("unable to remove PCP port mapping", metadata: ["error": .string("\(error)")])
            }
        }
        state.withLockedValue { $0 = nil }
        onStateChange(nil)
    }

    private func discoverDeviceDescriptionURL() throws -> URL? {
        let responseData = try performSSDPDiscovery()
        guard let responseData else { return nil }
        let headers = PortMappingUtilities.parseSSDPResponse(responseData)
        guard let location = headers["location"], let url = URL(string: location) else {
            return nil
        }
        return url
    }

    private func fetchDeviceDescription(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw PortMappingError.httpError
        }
        return data
    }

    private func parseServices(from data: Data, baseURL: URL) throws -> [UPnPServiceDescription] {
        let parser = UPnPDeviceDescriptionParser(baseURL: baseURL)
        return try parser.parse(data: data)
    }

    private func selectPreferredService(from services: [UPnPServiceDescription]) -> UPnPServiceDescription? {
        let priorities = [
            "urn:schemas-upnp-org:service:WANIPConnection:2",
            "urn:schemas-upnp-org:service:WANIPConnection:1",
            "urn:schemas-upnp-org:service:WANPPPConnection:1"
        ]

        for target in priorities {
            if let match = services.first(where: { $0.serviceType == target }) {
                return match
            }
        }
        for service in services where service.serviceType.contains("WANIPConnection") || service.serviceType.contains("WANPPPConnection") {
            return service
        }
        return nil
    }

    private func sendSOAPRequest(
        action: String,
        arguments: [String: String],
        service: UPnPServiceDescription
    ) async throws -> Data {
        var request = URLRequest(url: service.controlURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(service.serviceType)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        if let host = service.controlURL.host {
            var header = host
            if let port = service.controlURL.port {
                header += ":\(port)"
            }
            request.setValue(header, forHTTPHeaderField: "Host")
        }

        let body = soapEnvelope(action: action, serviceType: service.serviceType, arguments: arguments)
        request.httpBody = body
        request.setValue("\(body.count)", forHTTPHeaderField: "Content-Length")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PortMappingError.httpError
        }
        guard (200...299).contains(http.statusCode) else {
            throw PortMappingError.soapFault(code: http.statusCode, payload: data)
        }
        return data
    }

    private func soapEnvelope(action: String, serviceType: String, arguments: [String: String]) -> Data {
        var argumentXML = ""
        for (key, value) in arguments {
            argumentXML += "<\(key)>\(PortMappingUtilities.escapeXML(value))</\(key)>"
        }
        let body = """
        <?xml version="1.0"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:\(action) xmlns:u="\(serviceType)">
              \(argumentXML)
            </u:\(action)>
          </s:Body>
        </s:Envelope>
        """
        return Data(body.utf8)
    }

    private func performSSDPDiscovery() throws -> Data? {
        let socketDescriptor = try createUDPSocket()
        defer { close(socketDescriptor) }

        var enable: Int32 = 1
        withUnsafeBytes(of: &enable) { buffer in
            _ = setsockopt(socketDescriptor, SOL_SOCKET, SO_REUSEADDR, buffer.baseAddress, socklen_t(buffer.count))
        }

        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        withUnsafeBytes(of: &timeout) { buffer in
            _ = setsockopt(socketDescriptor, SOL_SOCKET, SO_RCVTIMEO, buffer.baseAddress, socklen_t(buffer.count))
        }

        var multicastAddress = sockaddr_in()
        multicastAddress.sin_family = sa_family_t(AF_INET)
        multicastAddress.sin_port = in_port_t(UInt16(1900).bigEndian)
        multicastAddress.sin_addr = in_addr(s_addr: inet_addr("239.255.255.250"))
        let request = """
        M-SEARCH * HTTP/1.1\r
        HOST: 239.255.255.250:1900\r
        MAN: \"ssdp:discover\"\r
        MX: 2\r
        ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r
        USER-AGENT: Box/0.1 UPnP/1.1\r
        \r
        """
        try request.withCString { pointer in
            let length = strlen(pointer)
            let sent = withUnsafePointer(to: &multicastAddress) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(socketDescriptor, pointer, length, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if sent < 0 {
                throw PortMappingError.socket(errno)
            }
        }

        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = recv(socketDescriptor, &buffer, buffer.count, 0)
        if bytesRead <= 0 {
            return nil
        }
        return Data(buffer[0..<bytesRead])
    }

    private func firstNonLoopbackIPv4Address() throws -> String? {
        var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPointer) == 0, let basePointer = ifaddrPointer else {
            let message = String(cString: strerror(errno))
            throw PortMappingError.network(message)
        }
        defer { freeifaddrs(basePointer) }

        var cursor = basePointer
        while true {
            let flags = Int32(bitPattern: UInt32(cursor.pointee.ifa_flags))
            guard (flags & Int32(IFF_UP)) != 0 else {
                if let next = cursor.pointee.ifa_next { cursor = next; continue } else { break }
            }
            guard (flags & Int32(IFF_LOOPBACK)) == 0 else {
                if let next = cursor.pointee.ifa_next { cursor = next; continue } else { break }
            }
            guard let addr = cursor.pointee.ifa_addr else {
                if let next = cursor.pointee.ifa_next { cursor = next; continue } else { break }
            }
            if Int32(addr.pointee.sa_family) == AF_INET {
                if let host = numericHostString(for: UnsafePointer(addr)) {
                    return host
                }
            }
            if let next = cursor.pointee.ifa_next {
                cursor = next
            } else {
                break
            }
        }
        return nil
    }

    private func performNATPMPMapping(gateway: String, lifetime: UInt32) throws -> (externalPort: UInt16, lifetime: UInt32, externalIPv4: String?) {
        let socketDescriptor = try createUDPSocket()
        defer { close(socketDescriptor) }

        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        withUnsafeBytes(of: &timeout) { buffer in
            _ = setsockopt(socketDescriptor, SOL_SOCKET, SO_RCVTIMEO, buffer.baseAddress, socklen_t(buffer.count))
        }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(5351).bigEndian)
        guard inet_pton(AF_INET, gateway, &addr.sin_addr) == 1 else {
            throw PortMappingError.network("invalid-gateway-address")
        }

        var request = [UInt8](repeating: 0, count: 12)
        request[0] = 0
        request[1] = 1
        request[4] = UInt8(port >> 8)
        request[5] = UInt8(port & 0xff)
        request[6] = UInt8(port >> 8)
        request[7] = UInt8(port & 0xff)
        request[8] = UInt8((lifetime >> 24) & 0xff)
        request[9] = UInt8((lifetime >> 16) & 0xff)
        request[10] = UInt8((lifetime >> 8) & 0xff)
        request[11] = UInt8(lifetime & 0xff)

        let sent = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(socketDescriptor, request, request.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if sent < 0 {
            throw PortMappingError.socket(errno)
        }

        var buffer = [UInt8](repeating: 0, count: 32)
        let bytesRead = recv(socketDescriptor, &buffer, buffer.count, 0)
        guard bytesRead >= 16 else {
            throw PortMappingError.natpmp("short-response")
        }
        guard buffer[0] == 0 else {
            throw PortMappingError.natpmp("unsupported-version")
        }
        guard buffer[1] == 0x81 else {
            throw PortMappingError.natpmp("unexpected-opcode")
        }
        let resultCode = (UInt16(buffer[2]) << 8) | UInt16(buffer[3])
        guard resultCode == 0 else {
            throw PortMappingError.natpmp("result-\(resultCode)")
        }
        let externalPort = (UInt16(buffer[8]) << 8) | UInt16(buffer[9])
        let assignedLifetime = UInt32(buffer[12]) << 24 | UInt32(buffer[13]) << 16 | UInt32(buffer[14]) << 8 | UInt32(buffer[15])
        let externalIPv4 = try? queryNATPMPExternalAddress(gateway: gateway)
        return (externalPort: externalPort, lifetime: assignedLifetime, externalIPv4: externalIPv4)
    }

    private func queryNATPMPExternalAddress(gateway: String) throws -> String? {
        let socketDescriptor = try createUDPSocket()
        defer { close(socketDescriptor) }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        withUnsafeBytes(of: &timeout) { buffer in
            _ = setsockopt(socketDescriptor, SOL_SOCKET, SO_RCVTIMEO, buffer.baseAddress, socklen_t(buffer.count))
        }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(5351).bigEndian)
        guard inet_pton(AF_INET, gateway, &addr.sin_addr) == 1 else {
            throw PortMappingError.network("invalid-gateway-address")
        }

        var request = [UInt8](repeating: 0, count: 2)
        let sent = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(socketDescriptor, &request, request.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if sent < 0 {
            throw PortMappingError.socket(errno)
        }

        var buffer = [UInt8](repeating: 0, count: 16)
        let bytesRead = recv(socketDescriptor, &buffer, buffer.count, 0)
        guard bytesRead >= 12 else {
            throw PortMappingError.natpmp("address-short-response")
        }
        guard buffer[0] == 0, buffer[1] == 0x80 else {
            throw PortMappingError.natpmp("address-unexpected-opcode")
        }
        let resultCode = (UInt16(buffer[2]) << 8) | UInt16(buffer[3])
        guard resultCode == 0 else {
            throw PortMappingError.natpmp("address-result-\(resultCode)")
        }
        let addressBytes = Array(buffer[8..<12])
        var addrValue = in_addr()
        addressBytes.withUnsafeBytes { pointer in
            if let base = pointer.baseAddress {
                memcpy(&addrValue.s_addr, base, 4)
            }
        }
        var output = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &addrValue, &output, socklen_t(INET_ADDRSTRLEN)) != nil else {
            return nil
        }
        let bytes = output.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        guard !bytes.isEmpty else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func performNATPMPDeletion(gateway: String, externalPort: UInt16) throws {
        let socketDescriptor = try createUDPSocket()
        defer { close(socketDescriptor) }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        withUnsafeBytes(of: &timeout) { buffer in
            _ = setsockopt(socketDescriptor, SOL_SOCKET, SO_RCVTIMEO, buffer.baseAddress, socklen_t(buffer.count))
        }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(5351).bigEndian)
        guard inet_pton(AF_INET, gateway, &addr.sin_addr) == 1 else {
            throw PortMappingError.network("invalid-gateway-address")
        }

        var request = [UInt8](repeating: 0, count: 12)
        request[0] = 0
        request[1] = 1
        request[4] = UInt8(port >> 8)
        request[5] = UInt8(port & 0xff)
        request[6] = UInt8(externalPort >> 8)
        request[7] = UInt8(externalPort & 0xff)

        let sent = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(socketDescriptor, request, request.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if sent < 0 {
            throw PortMappingError.socket(errno)
        }
    }

    private func performPCPMapping(context: inout PCPContext, lifetime: UInt32) throws -> (externalPort: UInt16, lifetime: UInt32, externalIPv4: String?) {
        let socketDescriptor = try createUDPSocket()
        defer { close(socketDescriptor) }
        defer { close(socketDescriptor) }

        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        withUnsafeBytes(of: &timeout) { buffer in
            _ = setsockopt(socketDescriptor, SOL_SOCKET, SO_RCVTIMEO, buffer.baseAddress, socklen_t(buffer.count))
        }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(5351).bigEndian)
        guard inet_pton(AF_INET, context.gateway, &addr.sin_addr) == 1 else {
            throw PortMappingError.network("invalid-gateway-address")
        }

        var request = [UInt8]()
        request.reserveCapacity(60)
        request.append(0x02)
        request.append(0x01)
        request.append(contentsOf: [0x00, 0x00])
        request.append(contentsOf: UInt32(lifetime).bigEndianBytes)
        request.append(contentsOf: context.clientAddress)
        request.append(contentsOf: context.nonce)
        request.append(0x00)
        request.append(context.protocolValue)
        request.append(contentsOf: [0x00, 0x00])
        request.append(contentsOf: context.internalPort.bigEndianBytes)
        request.append(contentsOf: context.internalPort.bigEndianBytes)
        request.append(contentsOf: context.suggestedExternalIP)

        let sent = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(socketDescriptor, request, request.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if sent < 0 {
            throw PortMappingError.socket(errno)
        }

        var buffer = [UInt8](repeating: 0, count: 128)
        let bytesRead = recv(socketDescriptor, &buffer, buffer.count, 0)
        guard bytesRead >= 60 else {
            throw PortMappingError.pcp("short-response")
        }
        guard buffer[0] == 0x02 else {
            throw PortMappingError.pcp("unsupported-version")
        }
        guard buffer[1] == 0x81 else {
            throw PortMappingError.pcp("unexpected-opcode")
        }
        let resultCode = UInt16(buffer[2]) << 8 | UInt16(buffer[3])
        guard resultCode == 0 else {
            throw PortMappingError.pcp("result-\(resultCode)")
        }
        let lifetimeSeconds = UInt32(buffer[4]) << 24 | UInt32(buffer[5]) << 16 | UInt32(buffer[6]) << 8 | UInt32(buffer[7])
        let opOffset = 24
        let responseNonce = Array(buffer[opOffset..<(opOffset + 12)])
        guard responseNonce == context.nonce else {
            throw PortMappingError.pcp("nonce-mismatch")
        }
        let assignedExternalPort = UInt16(buffer[opOffset + 8]) << 8 | UInt16(buffer[opOffset + 9])
        let externalIPBytes = Array(buffer[(opOffset + 10)..<(opOffset + 26)])
        let externalIPv4 = PortMappingUtilities.ipv6BytesToIPv4(externalIPBytes)
        context.externalIPv4 = externalIPv4
        return (externalPort: assignedExternalPort, lifetime: lifetimeSeconds, externalIPv4: externalIPv4)
    }

    private func tryPerformPCPPeer(context: inout PCPContext, externalPort: UInt16, lifetime: UInt32) {
        do {
            let peerState = try performPCPPeer(context: &context, externalPort: externalPort, lifetime: lifetime)
            context.peer = peerState
            logger.info(
                "PCP peer mapping established",
                metadata: [
                    "externalPort": "\(externalPort)",
                    "gateway": .string(context.gateway)
                ]
            )
        } catch {
            logger.debug(
                "PCP peer request failed",
                metadata: [
                    "error": .string("\(error)")
                ]
            )
            context.peer = PCPContext.PeerState(
                nonce: [],
                remotePeerIP: Array(repeating: 0, count: 16),
                remotePeerPort: 0,
                status: "error",
                lifetime: nil,
                lastUpdated: Date(),
                error: "\(error)",
                externalPort: externalPort
            )
        }
    }

    private func performPCPPeer(context: inout PCPContext, externalPort: UInt16, lifetime: UInt32) throws -> PCPContext.PeerState {
        let remotePeerIP = [UInt8](repeating: 0, count: 16)
        let remotePeerPort: UInt16 = 0
        let nonce = PortMappingUtilities.randomNonce(length: 12)
        let lifetimeSeconds = try sendPCPPeerRequest(
            context: context,
            nonce: nonce,
            remotePeerIP: remotePeerIP,
            remotePeerPort: remotePeerPort,
            lifetime: lifetime
        )
        let resolvedLifetime = lifetimeSeconds > 0 ? lifetimeSeconds : lifetime
        return PCPContext.PeerState(
            nonce: nonce,
            remotePeerIP: remotePeerIP,
            remotePeerPort: remotePeerPort,
            status: "ok",
            lifetime: resolvedLifetime,
            lastUpdated: Date(),
            error: nil,
            externalPort: externalPort
        )
    }

    private func performPCPPeerDeletion(context: inout PCPContext) throws {
        guard let peerState = context.peer else { return }
        defer { context.peer = nil }
        _ = try sendPCPPeerRequest(
            context: context,
            nonce: PortMappingUtilities.randomNonce(length: 12),
            remotePeerIP: peerState.remotePeerIP,
            remotePeerPort: peerState.remotePeerPort,
            lifetime: 0
        )
    }

    private func sendPCPPeerRequest(
        context: PCPContext,
        nonce: [UInt8],
        remotePeerIP: [UInt8],
        remotePeerPort: UInt16,
        lifetime: UInt32
    ) throws -> UInt32 {
        let socketDescriptor = try createUDPSocket()
        defer { close(socketDescriptor) }

        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        withUnsafeBytes(of: &timeout) { buffer in
            _ = setsockopt(socketDescriptor, SOL_SOCKET, SO_RCVTIMEO, buffer.baseAddress, socklen_t(buffer.count))
        }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(5351).bigEndian)
        guard inet_pton(AF_INET, context.gateway, &addr.sin_addr) == 1 else {
            throw PortMappingError.network("invalid-gateway-address")
        }

        var request = [UInt8]()
        request.reserveCapacity(60)
        request.append(0x02)
        request.append(0x02)
        request.append(contentsOf: [0x00, 0x00])
        request.append(contentsOf: UInt32(lifetime).bigEndianBytes)
        request.append(contentsOf: context.clientAddress)
        request.append(contentsOf: nonce)
        request.append(0x00)
        request.append(context.protocolValue)
        request.append(contentsOf: [0x00, 0x00])
        request.append(contentsOf: context.internalPort.bigEndianBytes)
        request.append(contentsOf: remotePeerPort.bigEndianBytes)
        request.append(contentsOf: remotePeerIP)

        let sent = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(socketDescriptor, request, request.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if sent < 0 {
            throw PortMappingError.socket(errno)
        }

        var buffer = [UInt8](repeating: 0, count: 128)
        let bytesRead = recv(socketDescriptor, &buffer, buffer.count, 0)
        guard bytesRead >= 60 else {
            throw PortMappingError.pcp("short-response")
        }
        guard buffer[0] == 0x02 else {
            throw PortMappingError.pcp("unsupported-version")
        }
        guard buffer[1] == 0x82 else {
            throw PortMappingError.pcp("unexpected-opcode")
        }
        let resultCode = UInt16(buffer[2]) << 8 | UInt16(buffer[3])
        guard resultCode == 0 else {
            throw PortMappingError.pcp("result-\(resultCode)")
        }
        let lifetimeSeconds = UInt32(buffer[4]) << 24 | UInt32(buffer[5]) << 16 | UInt32(buffer[6]) << 8 | UInt32(buffer[7])
        let opOffset = 24
        let responseNonce = Array(buffer[opOffset..<(opOffset + 12)])
        guard responseNonce == nonce else {
            throw PortMappingError.pcp("nonce-mismatch")
        }
        return lifetimeSeconds
    }

    private func performPCPDeletion(context: inout PCPContext) throws {
        _ = try performPCPMapping(context: &context, lifetime: 0)
    }

    private func performReachabilityProbe(externalIPv4: String, externalPort: UInt16) throws -> ReachabilitySnapshot {
#if os(Windows)
        throw ReachabilityError.unsupportedPlatform
#else
        let socketDescriptor = try createUDPSocket()
        defer { close(socketDescriptor) }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        withUnsafeBytes(of: &timeout) { buffer in
            _ = setsockopt(socketDescriptor, SOL_SOCKET, SO_RCVTIMEO, buffer.baseAddress, socklen_t(buffer.count))
        }

        var remoteAddress = sockaddr_in()
        remoteAddress.sin_family = sa_family_t(AF_INET)
        remoteAddress.sin_port = in_port_t(externalPort.bigEndian)
        guard inet_pton(AF_INET, externalIPv4, &remoteAddress.sin_addr) == 1 else {
            throw ReachabilityError.invalidAddress
        }

        let allocator = ByteBufferAllocator()
        let requestId = UUID()
        let helloPayload = try BoxCodec.encodeHelloPayload(status: .ok, versions: [1], allocator: allocator)
        let frame = BoxCodec.Frame(
            command: .hello,
            requestId: requestId,
            nodeId: nodeIdentifier,
            userId: userIdentifier,
            payload: helloPayload
        )
        let datagram = BoxCodec.encodeFrame(frame, allocator: allocator)
        let start = Date()
        let sent = datagram.withUnsafeReadableBytes { pointer -> Int in
            guard let baseAddress = pointer.baseAddress else { return -1 }
            return withUnsafePointer(to: &remoteAddress) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(socketDescriptor, baseAddress, pointer.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent < 0 {
            throw ReachabilityError.send(errno)
        }

        var buffer = [UInt8](repeating: 0, count: 1024)
        var sourceAddress = sockaddr_in()
        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bytesRead = withUnsafeMutablePointer(to: &sourceAddress) { pointer -> Int in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                recvfrom(socketDescriptor, &buffer, buffer.count, 0, sockaddrPointer, &addressLength)
            }
        }

        if bytesRead < 0 {
            if errno == EWOULDBLOCK || errno == EAGAIN {
                throw ReachabilityError.timeout
            }
            throw ReachabilityError.receive(errno)
        }
        guard bytesRead > 0 else {
            throw ReachabilityError.emptyResponse
        }

        var responseBuffer = allocator.buffer(capacity: bytesRead)
        responseBuffer.writeBytes(buffer[0..<bytesRead])
        var decodingBuffer = responseBuffer
        let frameResponse: BoxCodec.Frame
        do {
            frameResponse = try BoxCodec.decodeFrame(from: &decodingBuffer)
        } catch {
            throw ReachabilityError.decodeFailed(error)
        }
        guard frameResponse.requestId == requestId else {
            throw ReachabilityError.unexpectedResponse
        }
        guard frameResponse.command == .hello || frameResponse.command == .status else {
            throw ReachabilityError.unsupportedCommand(frameResponse.command.rawValue)
        }

        let end = Date()
        let elapsed = Int(end.timeIntervalSince(start) * 1_000)
        return ReachabilitySnapshot(
            status: "ok",
            lastChecked: end,
            roundTripMillis: elapsed,
            error: nil
        )
#endif
    }

    private func defaultGatewayIPv4() -> String? {
#if os(Linux)
        guard let contents = try? String(contentsOfFile: "/proc/net/route", encoding: .utf8) else { return nil }
        return PortMappingUtilities.defaultGateway(fromProcNetRoute: contents)
#elseif canImport(SystemConfiguration)
        guard let store = SCDynamicStoreCreate(nil, "box.portmapping" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let router = value["Router"] as? String else {
            return nil
        }
        return router
#else
        return nil
#endif
    }
#endif

    private func createUDPSocket() throws -> Int32 {
        #if os(Linux)
        let sockDGRAM = Int32(SOCK_DGRAM.rawValue)
        #else
        let sockDGRAM = SOCK_DGRAM
        #endif
        let socketDescriptor = socket(AF_INET, sockDGRAM, Int32(IPPROTO_UDP))
        guard socketDescriptor >= 0 else {
            throw PortMappingError.socket(errno)
        }
        return socketDescriptor
    }
}

enum ReachabilityError: Error, CustomStringConvertible {
    case unsupportedPlatform
    case invalidAddress
    case send(Int32)
    case receive(Int32)
    case timeout
    case emptyResponse
    case decodeFailed(Error)
    case unexpectedResponse
    case unsupportedCommand(UInt32)

    var description: String {
        switch self {
        case .unsupportedPlatform:
            return "reachability-error(unsupported-platform)"
        case .invalidAddress:
            return "reachability-error(invalid-address)"
        case .send(let code):
            return "reachability-error(send-\(code))"
        case .receive(let code):
            return "reachability-error(recv-\(code))"
        case .timeout:
            return "reachability-error(timeout)"
        case .emptyResponse:
            return "reachability-error(empty-response)"
        case .decodeFailed(let error):
            return "reachability-error(decode-failed:\(error))"
        case .unexpectedResponse:
            return "reachability-error(unexpected-response)"
        case .unsupportedCommand(let identifier):
            return "reachability-error(unsupported-command-\(identifier))"
        }
    }
}


private extension UInt16 {
    var bigEndianBytes: [UInt8] {
        let value = self.bigEndian
        return [
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
    }
}

private extension UInt32 {
    var bigEndianBytes: [UInt8] {
        let value = self.bigEndian
        return [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
    }
}
