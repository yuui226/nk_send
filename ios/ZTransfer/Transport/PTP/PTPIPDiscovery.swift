import Foundation

struct PTPIPCandidate: Equatable, Sendable {
    let ip: String
    let localAddress: String?
}

/// Pure discovery policy copied from Android PtpIpDiscovery.  Socket probing
/// remains in the platform adapter; keeping route math pure prevents scans from
/// accidentally crossing the active interface or producing duplicate hosts.
enum PTPIPDiscoveryPolicy {
    /// Camera AP uses 192.168.1.1 as the DHCP gateway; the phone address on
    /// that network therefore belongs to 192.168.1.0/24.
    static func isCameraHotspotAddress(_ address: String) -> Bool {
        parse(address).map { ($0 & ipv4Mask(24)) == parse("192.168.1.0")! } ?? false
    }

    static func effectiveScanPrefix(routePrefix: Int) -> Int {
        max(24, min(32, max(0, routePrefix)))
    }

    static func contains(localAddress: String, candidate: String, prefix: Int) -> Bool {
        guard let local = parse(localAddress), let remote = parse(candidate), (0...32).contains(prefix) else { return false }
        let mask = ipv4Mask(prefix)
        return (local & mask) == (remote & mask) && local != remote
    }

    static func hosts(localAddress: String, prefix: Int) -> [String] {
        guard let local = parse(localAddress), (0...32).contains(prefix) else { return [] }
        let mask = ipv4Mask(prefix)
        let network = local & mask
        let broadcast = network | (~mask & 0xFFFF_FFFF)
        guard broadcast > network + 1, broadcast - network - 1 <= 254 else { return [] }
        return (network + 1..<broadcast).filter { $0 != local }.map(format)
    }

    static func candidates(localAddress: String, routePrefix: Int) -> [PTPIPCandidate] {
        hosts(localAddress: localAddress, prefix: effectiveScanPrefix(routePrefix: routePrefix)).map {
            PTPIPCandidate(ip: $0, localAddress: localAddress)
        }
    }

    private static func parse(_ value: String) -> UInt64? {
        let parts = value.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var result: UInt64 = 0
        for part in parts {
            guard let octet = UInt64(part), octet <= 255 else { return nil }
            result = result << 8 | octet
        }
        return result
    }

    private static func format(_ value: UInt64) -> String {
        [24, 16, 8, 0].map { String((value >> $0) & 0xff) }.joined(separator: ".")
    }

    private static func ipv4Mask(_ prefix: Int) -> UInt64 {
        guard prefix > 0 else { return 0 }
        return (0xFFFF_FFFF << (32 - prefix)) & 0xFFFF_FFFF
    }
}
