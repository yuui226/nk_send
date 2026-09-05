package com.ztransfer.connection

import com.ztransfer.protocol.LabDeviceInfo

/** Native scalar/array facade over the existing STA decisions, not a second pairing policy. */
object NikonStaBridge {
    const val COMPATIBILITY_INIT = 0x941C
    const val PAIRING_EVENT_TIMEOUT_MS = 8_000L
    fun normalizeGuid(value: String?): String? = normalizeResponderGuid(value)
    fun expectedResponder(expected: String?, actual: String?): Boolean = isExpectedStaResponder(expected, actual)
    fun usableStorage(code: Int, ids: IntArray): Boolean = hasUsableStaAlbumStorage(code, ids.toList())
    fun pairingOnly(info: LabDeviceInfo?): Boolean = info != null && isStaPairingOnlyOperationSet(info.operations)
    fun forcePairing(code: Int, force: Boolean, allow: Boolean, marked: Boolean): Boolean =
        shouldForceStaProfilePairing(code, force, allow, marked)
}
