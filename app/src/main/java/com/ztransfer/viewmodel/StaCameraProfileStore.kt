package com.ztransfer.viewmodel

import android.content.SharedPreferences
import com.ztransfer.connection.StaInitiatorIdentity
import com.ztransfer.protocol.STA_PAIRING_MARKER_PREFIX

/**
 * One ZTransfer installation is one PTP/IP initiator. Cameras remember that shared computer
 * identity; this store only keeps the per-body routing hints needed to find it again.
 */
internal data class StaCameraProfile(
    val responderGuid: String,
    val lastIp: String?,
    val preferredIdentity: StaInitiatorIdentity,
    val pairingConfirmed: Boolean,
    val lastSeenAtMs: Long,
    val deviceModel: String? = null,
)

internal class StaCameraProfileStore(
    private val preferences: SharedPreferences,
    private val pairingPreferences: SharedPreferences,
    private val nowMs: () -> Long = System::currentTimeMillis,
) {
    init {
        migrateLegacyPairingMarkers()
    }

    fun lastUsedIp(): String? =
        preferences.getString(KEY_LAST_CAMERA_IP, null)?.takeIf(String::isNotBlank)

    fun hasAnyReusableProfile(): Boolean =
        allProfiles().any(StaCameraProfile::pairingConfirmed) ||
            preferences.getBoolean(KEY_REUSABLE_PROFILE, false) ||
            lastUsedIp() != null

    fun profileForGuid(responderGuid: String?): StaCameraProfile? {
        val guid = normalizeResponderGuid(responderGuid) ?: return null
        val registered = guid in storedGuids() || pairingMarkerExists(guid)
        if (!registered) return null
        return StaCameraProfile(
            responderGuid = guid,
            lastIp = preferences.getString(profileKey(guid, FIELD_LAST_IP), null)
                ?.takeIf(String::isNotBlank),
            preferredIdentity = restoredStaInitiatorIdentity(
                preferences.getString(profileKey(guid, FIELD_IDENTITY), null),
            ),
            // Route discovery can succeed while the camera is still waiting for pairing. Only the
            // marker written after NK_PAIRING_RESULT succeeds is authoritative; the profile field
            // is legacy data and may contain a false positive from an older connection.
            pairingConfirmed = pairingMarkerExists(guid),
            lastSeenAtMs = preferences.getLong(profileKey(guid, FIELD_LAST_SEEN), 0L),
            deviceModel = preferences.getString(profileKey(guid, FIELD_DEVICE_MODEL), null)
                ?.trim()
                ?.takeIf(String::isNotEmpty),
        )
    }

    fun profileForIp(ip: String): StaCameraProfile? =
        mostRecentStaProfileForIp(allProfiles(), ip)

    fun hasReusableProfileUsing(identity: StaInitiatorIdentity): Boolean =
        hasReusableStaProfileUsing(allProfiles(), identity)

    fun pairedResponderGuids(): Set<String> = allProfiles()
        .asSequence()
        .filter(StaCameraProfile::pairingConfirmed)
        .map(StaCameraProfile::responderGuid)
        .toSet()

    fun pairedCameraCount(): Int = pairedResponderGuids().size

    fun pairedCameraModels(): List<String> = allProfiles()
        .asSequence()
        .filter(StaCameraProfile::pairingConfirmed)
        .sortedByDescending(StaCameraProfile::lastSeenAtMs)
        .mapNotNull(StaCameraProfile::deviceModel)
        .toList()

    fun mostRecentlyUsedResponderGuid(): String? {
        normalizeResponderGuid(preferences.getString(KEY_LAST_RESPONDER_GUID, null))
            ?.takeIf { profileForGuid(it)?.pairingConfirmed == true }
            ?.let { return it }
        return mostRecentlyUsedStaProfile(allProfiles(), lastUsedIp())?.responderGuid
    }

    /** The IP match is only a fast hint; the responder GUID remains the authoritative body ID. */
    fun preferredIdentityFor(ip: String): StaInitiatorIdentity =
        preferredStaIdentityForCandidate(
            ip = ip,
            profiles = allProfiles(),
        )

    fun isKnownCandidate(ip: String, responderGuid: String? = null): Boolean =
        if (responderGuid != null) {
            profileForGuid(responderGuid)?.pairingConfirmed == true
        } else {
            profileForIp(ip)?.pairingConfirmed == true ||
                (lastUsedIp() == ip && preferences.getBoolean(KEY_REUSABLE_PROFILE, false))
        }

    /**
     * Records a successful body-specific route while retaining the old last-camera keys as a
     * migration/launch accelerator. A synchronous write is intentional: pairing restarts Nikon's
     * service immediately, and the profile must survive the app being killed during that window.
     */
    @Synchronized
    fun rememberConnection(
        responderGuid: String?,
        ip: String,
        identity: StaInitiatorIdentity,
        deviceModel: String? = null,
    ) {
        val guid = normalizeResponderGuid(responderGuid)
        val normalizedModel = deviceModel?.trim()?.takeIf(String::isNotEmpty)
        val editor = preferences.edit()
            .putBoolean(KEY_REUSABLE_PROFILE, true)
            .putString(KEY_LAST_CAMERA_IP, ip)
            .putString(KEY_LEGACY_LAST_IDENTITY, identity.name)
        if (guid != null) {
            val guids = storedGuids().toMutableSet().apply { add(guid) }
            editor
                .putStringSet(KEY_PROFILE_GUIDS, guids)
                .putString(KEY_LAST_RESPONDER_GUID, guid)
                .putString(profileKey(guid, FIELD_LAST_IP), ip)
                .putString(profileKey(guid, FIELD_IDENTITY), identity.name)
                .putLong(profileKey(guid, FIELD_LAST_SEEN), nowMs())
            if (normalizedModel != null) {
                editor.putString(profileKey(guid, FIELD_DEVICE_MODEL), normalizedModel)
            }
        } else {
            editor.remove(KEY_LAST_RESPONDER_GUID)
        }
        editor.commit()
    }

    /**
     * Forgets every camera bound to this installation and rotates the shared PTP/IP initiator on
     * the next pairing. The wireless-mode preference is intentionally retained.
     */
    @Synchronized
    fun resetPairing() {
        val connectionEditor = preferences.edit()
            .remove(KEY_REUSABLE_PROFILE)
            .remove(KEY_LAST_CAMERA_IP)
            .remove(KEY_LAST_RESPONDER_GUID)
            .remove(KEY_LEGACY_LAST_IDENTITY)
            .remove(KEY_PROFILE_GUIDS)
            .putBoolean(KEY_PROFILE_MIGRATION_COMPLETE, true)
        preferences.all.keys
            .filter { it.startsWith(PROFILE_PREFIX) }
            .forEach(connectionEditor::remove)
        connectionEditor.commit()

        // ptpip_identity is dedicated to the two initiator IDs and per-camera pairing markers.
        pairingPreferences.edit().clear().commit()
    }

    private fun allProfiles(): List<StaCameraProfile> {
        val guids = storedGuids().toMutableSet()
        pairingPreferences.all.forEach { (key, value) ->
            if (value == true && key.startsWith(STA_PAIRING_MARKER_PREFIX)) {
                normalizeResponderGuid(key.removePrefix(STA_PAIRING_MARKER_PREFIX))
                    ?.let(guids::add)
            }
        }
        return guids.mapNotNull(::profileForGuid)
    }

    /**
     * Older builds already wrote one marker per responder GUID but only one global IP/route.
     * Preserve every marker. The legacy IP can be assigned only when there is exactly one body;
     * with several bodies guessing would attach the route to the wrong camera.
     */
    @Synchronized
    private fun migrateLegacyPairingMarkers() {
        if (preferences.getBoolean(KEY_PROFILE_MIGRATION_COMPLETE, false)) return
        val markerGuids = pairingPreferences.all.mapNotNull { (key, value) ->
            if (value == true && key.startsWith(STA_PAIRING_MARKER_PREFIX)) {
                normalizeResponderGuid(key.removePrefix(STA_PAIRING_MARKER_PREFIX))
            } else {
                null
            }
        }.toSet()
        if (markerGuids.isEmpty()) {
            preferences.edit().putBoolean(KEY_PROFILE_MIGRATION_COMPLETE, true).apply()
            return
        }

        val knownGuids = storedGuids().toMutableSet().apply { addAll(markerGuids) }
        val onlyGuid = knownGuids.singleOrNull()
        val legacyIp = lastUsedIp()
        val legacyIdentity = restoredStaInitiatorIdentity(
            preferences.getString(KEY_LEGACY_LAST_IDENTITY, null),
        )
        val editor = preferences.edit()
            .putStringSet(KEY_PROFILE_GUIDS, knownGuids)
            .putBoolean(KEY_PROFILE_MIGRATION_COMPLETE, true)
        if (onlyGuid != null) {
            editor.putString(KEY_LAST_RESPONDER_GUID, onlyGuid)
        }
        markerGuids.forEach { guid ->
            editor.putBoolean(profileKey(guid, FIELD_PAIRED), true)
            if (!preferences.contains(profileKey(guid, FIELD_IDENTITY))) {
                editor.putString(
                    profileKey(guid, FIELD_IDENTITY),
                    if (guid == onlyGuid) legacyIdentity.name
                    else StaInitiatorIdentity.PAIRED_COMPUTER.name,
                )
            }
            if (guid == onlyGuid && legacyIp != null &&
                !preferences.contains(profileKey(guid, FIELD_LAST_IP))
            ) {
                editor.putString(profileKey(guid, FIELD_LAST_IP), legacyIp)
            }
        }
        editor.apply()
    }

    private fun storedGuids(): Set<String> =
        preferences.getStringSet(KEY_PROFILE_GUIDS, emptySet()).orEmpty()
            .mapNotNull(::normalizeResponderGuid)
            .toSet()

    private fun pairingMarkerExists(guid: String): Boolean =
        pairingPreferences.getBoolean("$STA_PAIRING_MARKER_PREFIX$guid", false)

    private fun profileKey(guid: String, field: String): String =
        "$PROFILE_PREFIX$guid.$field"

    private companion object {
        const val KEY_REUSABLE_PROFILE = "sta_reusable_profile"
        const val KEY_LAST_CAMERA_IP = "last_sta_camera_ip"
        const val KEY_LAST_RESPONDER_GUID = "last_sta_responder_guid_v1"
        const val KEY_LEGACY_LAST_IDENTITY = "sta_last_initiator_identity"
        const val KEY_PROFILE_GUIDS = "sta_camera_profile_guids_v1"
        const val KEY_PROFILE_MIGRATION_COMPLETE = "sta_camera_profile_migration_v1"
        const val PROFILE_PREFIX = "sta_camera_profile_v1."
        const val FIELD_LAST_IP = "last_ip"
        const val FIELD_IDENTITY = "identity"
        const val FIELD_PAIRED = "paired"
        const val FIELD_LAST_SEEN = "last_seen"
        const val FIELD_DEVICE_MODEL = "device_model"
    }
}

private val RESPONDER_GUID_PATTERN = Regex("[0-9a-f]{32}")

internal fun normalizeResponderGuid(value: String?): String? = value
    ?.trim()
    ?.lowercase()
    ?.takeIf(RESPONDER_GUID_PATTERN::matches)

internal fun mostRecentStaProfileForIp(
    profiles: List<StaCameraProfile>,
    ip: String,
): StaCameraProfile? = profiles.asSequence()
    .filter { it.lastIp == ip }
    .maxByOrNull(StaCameraProfile::lastSeenAtMs)

internal fun preferredStaIdentityForCandidate(
    ip: String,
    profiles: List<StaCameraProfile>,
): StaInitiatorIdentity = mostRecentStaProfileForIp(
    profiles = profiles.filter(StaCameraProfile::pairingConfirmed),
    ip = ip,
)?.preferredIdentity
    ?: StaInitiatorIdentity.PAIRED_COMPUTER

internal fun hasReusableStaProfileUsing(
    profiles: List<StaCameraProfile>,
    identity: StaInitiatorIdentity,
): Boolean = profiles.any {
    it.pairingConfirmed && it.preferredIdentity == identity
}

internal fun mostRecentlyUsedStaProfile(
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
