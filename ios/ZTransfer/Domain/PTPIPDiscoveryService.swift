import Foundation
import Network

/// PtpIpDiscovery.kt: saved route first; mDNS runs alongside bounded subnet
/// batches. Port probes overlap, but complete Nikon handshakes stay sequential.
final class PTPIPDiscoveryService: Sendable {
    func isOnCameraHotspot() -> Bool {
        localInterfaces().contains { PTPIPDiscoveryPolicy.isCameraHotspotAddress($0.address) }
    }

    func discover<Value: Sendable>(lastIP: String? = nil,
        onProgress: @escaping @Sendable (String) async -> Void,
        tryCandidate: @escaping @Sendable (PTPIPCandidate) async throws -> Value?) async throws -> Value? {
        let interfaces = localInterfaces()
        var tried = Set<String>()
        func tryOnce(_ candidate: PTPIPCandidate) async throws -> Value? {
            try Task.checkCancellation()
            guard tried.insert(candidate.ip).inserted else { return nil }
            await onProgress(candidate.ip)
            return try await tryCandidate(candidate)
        }
        if let lastIP, let route = interfaces.first(where: {
            PTPIPDiscoveryPolicy.contains(localAddress: $0.address, candidate: lastIP, prefix: $0.prefix)
        }) {
            let candidate = PTPIPCandidate(ip: lastIP, localAddress: route.address)
            if await probe(candidate), let result = try await tryOnce(candidate) { return result }
        }
        let mailbox = MDNSResult()
        let mdns = Task {
            let addresses = await STABonjourDiscovery.discover()
            await mailbox.finish(addresses)
        }
        defer { mdns.cancel() }
        var mdnsConsumed = false
        func tryMDNS(wait: Bool) async throws -> Value? {
            guard !mdnsConsumed else { return nil }
            if wait { await withTaskCancellationHandler { await mdns.value } onCancel: { mdns.cancel() } }
            guard let addresses = await mailbox.addresses else { return nil }
            mdnsConsumed = true
            for ip in addresses {
                let local = interfaces.first {
                    PTPIPDiscoveryPolicy.contains(localAddress: $0.address, candidate: ip, prefix: $0.prefix)
                }?.address
                if let result = try await tryOnce(PTPIPCandidate(ip: ip, localAddress: local)) { return result }
            }
            return nil
        }
        for route in interfaces {
            let candidates = PTPIPDiscoveryPolicy.candidates(localAddress: route.address, routePrefix: route.prefix)
            for offset in stride(from: 0, to: candidates.count, by: 48) {
                try Task.checkCancellation()
                if let result = try await tryMDNS(wait: false) { return result }
                let batch = Array(candidates[offset..<min(offset + 48, candidates.count)])
                let open = await probeBatch(batch)
                if let result = try await tryMDNS(wait: false) { return result }
                for candidate in open {
                    if let result = try await tryOnce(candidate) { return result }
                }
            }
        }
        return try await tryMDNS(wait: true)
    }

    private func probeBatch(_ candidates: [PTPIPCandidate]) async -> [PTPIPCandidate] {
        await withTaskGroup(of: (Int, Bool).self) { group in
            var next = 0
            var reachable = Set<Int>()
            while next < min(24, candidates.count) {
                let index = next; next += 1
                group.addTask { (index, await self.probe(candidates[index])) }
            }
            while let (index, open) = await group.next() {
                if open { reachable.insert(index) }
                if next < candidates.count, !Task.isCancelled {
                    let index = next; next += 1
                    group.addTask { (index, await self.probe(candidates[index])) }
                }
            }
            return candidates.indices.filter { reachable.contains($0) }.map { candidates[$0] }
        }
    }

    private func probe(_ candidate: PTPIPCandidate) async -> Bool {
        guard !Task.isCancelled else { return false }
        let connection = NWConnection(host: .init(candidate.ip), port: .init(rawValue: 15740)!,
            using: PTPIPSocketTransport.parameters(localAddress: candidate.localAddress, sta: true))
        defer { connection.cancel() }
        do {
            return try await AsyncDeadline.run(nanoseconds: 450_000_000, timeoutError: PTPSessionError.timeout) {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        let flag = ProbeFlag()
                        connection.stateUpdateHandler = { state in
                            switch state {
                            case .ready:
                                if flag.claim() { continuation.resume(returning: true) }
                            case .failed, .cancelled:
                                if flag.claim() { continuation.resume(returning: false) }
                            default: break
                            }
                        }
                        connection.start(queue: .global(qos: .utility))
                    }
                } onCancel: { connection.cancel() }
            }
        } catch { return false }
    }

    private struct InterfaceAddress { let address: String; let prefix: Int }
    private func localInterfaces() -> [InterfaceAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [InterfaceAddress] = []
        var seenSubnets = Set<String>()
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            let flags = Int32(item.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & (IFF_LOOPBACK | IFF_POINTOPOINT) == 0,
                  let address = item.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  let namePointer = item.pointee.ifa_name, let netmask = item.pointee.ifa_netmask else { continue }
            let name = String(cString: namePointer).lowercased()
            guard !["pdp", "wwan", "utun", "tun", "tap", "rmnet", "ccmni", "v4-rmnet", "awdl", "llw"]
                .contains(where: { name.hasPrefix($0) }) else { continue }
            let addr = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee
            let mask = UnsafeRawPointer(netmask).assumingMemoryBound(to: sockaddr_in.self).pointee
            let hostOrder = UInt32(bigEndian: addr.sin_addr.s_addr)
            let privateAddress = hostOrder >> 24 == 10 || hostOrder >> 20 == 0xAC1 || hostOrder >> 16 == 0xC0A8
            let prefix = mask.sin_addr.s_addr.nonzeroBitCount
            guard privateAddress, (8...30).contains(prefix) else { continue }
            var ip = addr.sin_addr
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &ip, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let addressString = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let scanPrefix = PTPIPDiscoveryPolicy.effectiveScanPrefix(routePrefix: prefix)
            let scanMask = UInt32.max << (32 - scanPrefix)
            guard seenSubnets.insert("\(hostOrder & scanMask)/\(scanPrefix)").inserted else { continue }
            result.append(InterfaceAddress(address: addressString, prefix: prefix))
        }
        return result
    }
}

private actor MDNSResult {
    private(set) var addresses: [String]?
    func finish(_ values: [String]) { addresses = values }
}

/// The run-loop adapter is the only platform-specific part of Android's NSD
/// discovery. Stop browsers/resolvers on cancellation; never retain a scan.
@MainActor
private final class STABonjourDiscovery: NSObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var addresses: [String] = []
    private var firstAddressWaiter: CheckedContinuation<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    static func discover() async -> [String] {
        for type in ["_ptp._tcp.", "_nikon._tcp."] {
            guard !Task.isCancelled else { return [] }
            let scan = STABonjourDiscovery()
            scan.browser.delegate = scan
            scan.browser.searchForServices(ofType: type, inDomain: "local.")
            await scan.waitForFirstAddressOrTimeout()
            scan.browser.stop()
            scan.services.forEach { $0.stop() }
            guard !Task.isCancelled else { return [] }
            if !scan.addresses.isEmpty { return scan.addresses }
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return [] }
        }
        return []
    }

    /// Android's NSD continuation resumes as soon as the first IPv4 service
    /// resolves; the 1.5 s value is only an upper bound. Keeping a fixed sleep
    /// here delayed the fastest STA discovery path even after the camera was
    /// already known.
    private func waitForFirstAddressOrTimeout() async {
        if !addresses.isEmpty { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if !addresses.isEmpty || Task.isCancelled {
                    continuation.resume()
                    return
                }
                firstAddressWaiter = continuation
                timeoutTask = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 1_500_000_000) } catch {}
                    guard let self else { return }
                    self.finishAddressWait()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishAddressWait() }
        }
    }

    private func finishAddressWait() {
        timeoutTask?.cancel()
        timeoutTask = nil
        let waiter = firstAddressWaiter
        firstAddressWaiter = nil
        waiter?.resume()
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 1.5)
    }
    func netServiceDidResolveAddress(_ sender: NetService) {
        for data in sender.addresses ?? [] where data.count >= MemoryLayout<sockaddr_in>.size {
            var address = data.withUnsafeBytes { $0.loadUnaligned(as: sockaddr_in.self) }
            guard address.sin_family == UInt8(AF_INET) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &address.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let ip = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if !addresses.contains(ip) {
                addresses.append(ip)
                finishAddressWait()
            }
        }
    }
}

private final class ProbeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; guard !claimed else { return false }; claimed = true; return true }
}
