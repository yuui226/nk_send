package com.ztransfer.connection

data class StaCameraProfile(
    val responderGuid: String,
    val lastIp: String?,
    val preferredIdentity: StaInitiatorIdentity,
    val pairingConfirmed: Boolean,
    val lastSeenAtMs: Long,
    val deviceModel: String? = null,
)

private val RESPONDER_GUID_PATTERN = Regex("[0-9a-f]{32}")

fun normalizeResponderGuid(value: String?): String? = value
    ?.trim()
    ?.lowercase()
    ?.takeIf(RESPONDER_GUID_PATTERN::matches)

fun mostRecentStaProfileForIp(
    profiles: List<StaCameraProfile>,
    ip: String,
): StaCameraProfile? = profiles.asSequence()
    .filter { it.lastIp == ip }
    .maxByOrNull(StaCameraProfile::lastSeenAtMs)

fun preferredStaIdentityForCandidate(
    ip: String,
    profiles: List<StaCameraProfile>,
): StaInitiatorIdentity = mostRecentStaProfileForIp(
    profiles = profiles.filter(StaCameraProfile::pairingConfirmed),
    ip = ip,
)?.preferredIdentity
    ?: StaInitiatorIdentity.PAIRED_COMPUTER

fun hasReusableStaProfileUsing(
    profiles: List<StaCameraProfile>,
    identity: StaInitiatorIdentity,
): Boolean = profiles.any {
    it.pairingConfirmed && it.preferredIdentity == identity
}

fun mostRecentlyUsedStaProfile(
    profiles: List<StaCameraProfile>,
    lastUsedIp: String?,
): StaCameraProfile? {
    val confirmedProfiles = profiles.filter(StaCameraProfile::pairingConfirmed)
    if (lastUsedIp != null) {
        mostRecentStaProfileForIp(confirmedProfiles, lastUsedIp)?.let { return it }
    }
    return confirmedProfiles.asSequence()
        .filter { it.lastSeenAtMs > 0L }
        .maxByOrNull(StaCameraProfile::lastSeenAtMs)
}
