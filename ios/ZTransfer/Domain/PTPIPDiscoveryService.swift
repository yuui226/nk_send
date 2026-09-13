import Foundation
import Network

enum PTPIPDiscoveryError: Error, Equatable, Sendable { case notFound }

/// Discovers Nikon PTP/IP endpoints on the active Wi-Fi interface. Discovery
/// only reports a host with an open PTP port; the protocol handshake remains in
/// PTPIPSocketTransport so a false positive cannot enter the photo page.
final class PTPIPDiscoveryService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.ztransfer.ptpip.discovery")

    /// Android AP discovery only probes when the DHCP gateway is 192.168.1.1.
    /// iOS does not expose DHCP gateway through Network.framework, so use the
    /// same fixed camera subnet as the conservative candidate gate. The actual
    /// PTP/IP handshake remains the authoritative identity check.
    func isOnCameraHotspot() -> Bool {
        localWiFiInterfaces().contains { PTPIPDiscoveryPolicy.isCameraHotspotAddress($0.address) }
    }

    func discover(lastIP: String? = nil, onProgress: @escaping @Sendable (String) -> Void = { _ in }) async -> PTPIPCandidate? {
        let interfaces = localWiFiInterfaces()
        var candidates: [PTPIPCandidate] = []
        if let lastIP, interfaces.contains(where: { PTPIPDiscoveryPolicy.contains(localAddress: $0.address, candidate: lastIP, prefix: $0.prefix) }) {
            candidates.append(PTPIPCandidate(ip: lastIP, localAddress: interfaces.first!.address))
        }
        for interface in interfaces {
            candidates.append(contentsOf: PTPIPDiscoveryPolicy.candidates(localAddress: interface.address, routePrefix: interface.prefix))
        }
        var seen = Set<String>()
        candidates = candidates.filter { seen.insert($0.ip).inserted }
        return await withTaskGroup(of: PTPIPCandidate?.self, returning: PTPIPCandidate?.self) { group in
            var iterator = candidates.makeIterator()
            let concurrency = min(24, max(1, candidates.count))
            for _ in 0..<concurrency {
                guard let candidate = iterator.next() else { break }
                group.addTask { [weak self] in
                    await self?.probe(candidate, onProgress: onProgress)
                }
            }
            while let result = await group.next() {
                if let result { group.cancelAll(); return result }
                guard let candidate = iterator.next() else { continue }
                group.addTask { [weak self] in await self?.probe(candidate, onProgress: onProgress) }
            }
            return nil
        }
    }

    private func probe(_ candidate: PTPIPCandidate, onProgress: @escaping @Sendable (String) -> Void) async -> PTPIPCandidate? {
        onProgress(candidate.ip)
        let parameters: NWParameters = {
            let value = NWParameters.tcp
            value.requiredInterfaceType = .wifi
            value.prohibitedInterfaceTypes = [.loopback]
            return value
        }()
        let connection = NWConnection(host: NWEndpoint.Host(candidate.ip), port: NWEndpoint.Port(rawValue: 15740)!, using: parameters)
        let ready = await withTaskCancellationHandler(operation: {
            await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
                group.addTask {
                    await withCheckedContinuation { continuation in
                        let flag = ProbeFlag()
                        connection.stateUpdateHandler = { state in
                            switch state {
                            case .ready:
                                guard flag.claim() else { return }; continuation.resume(returning: true)
                            case .failed, .cancelled:
                                guard flag.claim() else { return }; continuation.resume(returning: false)
                            default: break
                            }
                        }
                        connection.start(queue: self.queue)
                    }
                }
                group.addTask {
                    try? await Task.sleep(for: .milliseconds(450))
                    return false
                }
                let result = await group.next() ?? false
                group.cancelAll()
                connection.cancel()
                return result
            }
        }, onCancel: { connection.cancel() })
        return ready ? candidate : nil
    }

    private struct InterfaceAddress {
        let address: String
        let prefix: Int
    }

    private func localWiFiInterfaces() -> [InterfaceAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [InterfaceAddress] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            guard let address = item.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  let name = item.pointee.ifa_name,
                  String(cString: name) == "en0" || String(cString: name) == "en1",
                  let netmask = item.pointee.ifa_netmask else { continue }
            let addressString = withUnsafePointer(to: address.pointee) { pointer in
                pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { value in
                    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    var sin = value.pointee.sin_addr
                    return String(cString: inet_ntop(AF_INET, &sin, &buffer, socklen_t(INET_ADDRSTRLEN)))
                }
            }
            let mask = withUnsafePointer(to: netmask.pointee) { pointer in
                pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            }
            let prefix = mask.nonzeroBitCount
            if !addressString.isEmpty, prefix >= 8 { result.append(InterfaceAddress(address: addressString, prefix: prefix)) }
        }
        return result
    }
}

private final class ProbeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; guard !claimed else { return false }; claimed = true; return true }
}
