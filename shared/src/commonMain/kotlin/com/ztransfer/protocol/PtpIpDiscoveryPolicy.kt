package com.ztransfer.protocol

private const val MAX_PTP_SCAN_HOSTS = 254L

/** Broad routes keep their real membership mask but active probing is bounded to the local /24. */
fun effectivePtpScanPrefix(routePrefixLength: Int): Int =
    routePrefixLength.coerceIn(0, 32).coerceAtLeast(24)

/** Tests IPv4 route membership while rejecting the local interface address itself. */
fun ipv4SubnetContains(
    localAddress: String,
    candidateIp: String,
    prefixLength: Int,
): Boolean {
    if (prefixLength !in 0..32) return false
    val localIp = parseIpv4(localAddress) ?: return false
    val candidate = parseIpv4(candidateIp) ?: return false
    val mask = ipv4Mask(prefixLength)
    return (candidate and mask) == (localIp and mask) && candidate != localIp
}

/** Stable key used to deduplicate interfaces that expose the same bounded scan range. */
fun ipv4SubnetKey(localAddress: String, prefixLength: Int): String? {
    if (prefixLength !in 0..32) return null
    val localIp = parseIpv4(localAddress) ?: return null
    val mask = ipv4Mask(prefixLength)
    return "${longToIpv4(localIp and mask)}/$prefixLength"
}

/** Enumerates usable hosts in ascending order, excluding network, broadcast and the local host. */
fun ipv4ScanHosts(localAddress: String, prefixLength: Int): List<String> {
    if (prefixLength !in 0..32) return emptyList()
    val localIp = parseIpv4(localAddress) ?: return emptyList()
    val mask = ipv4Mask(prefixLength)
    val network = localIp and mask
    val broadcast = network or mask.inv().and(0xFFFFFFFFL)
    val count = broadcast - network - 1
    if (count <= 0 || count > MAX_PTP_SCAN_HOSTS) return emptyList()
    return (network + 1 until broadcast)
        .asSequence()
        .filter { it != localIp }
        .map(::longToIpv4)
        .toList()
}

private fun parseIpv4(value: String): Long? {
    val parts = value.split('.')
    if (parts.size != 4) return null
    var result = 0L
    for (part in parts) {
        val octet = part.toIntOrNull()?.takeIf { it in 0..255 } ?: return null
        result = (result shl 8) or octet.toLong()
    }
    return result
}

private fun longToIpv4(value: Long): String = listOf(24, 16, 8, 0)
    .joinToString(".") { shift -> ((value shr shift) and 0xFF).toString() }

private fun ipv4Mask(prefixLength: Int): Long =
    if (prefixLength == 0) 0L
    else (0xFFFFFFFFL shl (32 - prefixLength)) and 0xFFFFFFFFL
