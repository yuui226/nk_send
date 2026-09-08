package com.ztransfer.connection

/** Pure syntax validation for an explicitly selected PTP host. Never resolves DNS or scans a subnet. */
object NativeCameraEndpointAddress {
    /** Port remains the existing PTP port; URLs and host:port input are deliberately rejected. */
    fun normalize(raw: String): String? {
        val value = raw.trim()
        if (value.isEmpty() || value.length > 253 || value.any { it.code !in 33..126 }) return null
        if (value.any { it in "/\\?#@" }) return null
        val bracketed = value.startsWith('[') || value.endsWith(']')
        val host = if (bracketed) {
            if (!value.startsWith('[') || !value.endsWith(']')) return null
            value.substring(1, value.length - 1)
        } else value
        if (':' in host) {
            val parts = host.split('%')
            if (parts.size > 2) return null
            val address = parts[0]
            val zone = parts.getOrNull(1)
            if (zone != null && (zone.isEmpty() || zone.length > 32 || zone.any { !it.isAsciiAlphaNumeric() && it !in "_.-" })) return null
            if (!ipv6(address)) return null
            return address.lowercase() + (zone?.let { "%$it" } ?: "")
        }
        if (bracketed || '%' in host) return null
        if (host.all { it in '0'..'9' || it == '.' }) return host.takeIf(::ipv4)
        val normalized = host.removeSuffix(".").lowercase()
        if (normalized.isEmpty()) return null
        val labels = normalized.split('.')
        if (labels.any { label -> label.isEmpty() || label.length > 63 || label.first() == '-' || label.last() == '-' ||
                label.any { !it.isAsciiAlphaNumeric() && it != '-' } }) return null
        return normalized
    }

    private fun Char.isAsciiAlphaNumeric(): Boolean = this in 'a'..'z' || this in 'A'..'Z' || this in '0'..'9'

    private fun ipv4(value: String): Boolean {
        val parts = value.split('.')
        return parts.size == 4 && parts.all {
            it.isNotEmpty() && it.length <= 3 && (it.length == 1 || it[0] != '0') &&
                it.all { char -> char in '0'..'9' } && (it.toIntOrNull() ?: -1) in 0..255
        }
    }

    private fun ipv6(value: String): Boolean {
        if (value.isEmpty() || value.count { it == ':' } < 2 || value.contains(":::")) return false
        val halves = value.split("::")
        if (halves.size > 2) return false
        if (halves.size == 1 && (value.startsWith(':') || value.endsWith(':'))) return false
        val groups = halves.flatMap { if (it.isEmpty()) emptyList() else it.split(':') }
        var units = 0
        groups.forEachIndexed { index, group ->
            if ('.' in group) {
                if (index != groups.lastIndex || !value.endsWith(group) || !ipv4(group)) return false
                units += 2
            } else {
                if (group.isEmpty() || group.length > 4 || group.any { it !in '0'..'9' && it !in 'a'..'f' && it !in 'A'..'F' }) return false
                units++
            }
        }
        return if (halves.size == 2) units < 8 else units == 8
    }
}
