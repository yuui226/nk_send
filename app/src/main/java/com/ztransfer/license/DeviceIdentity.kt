package com.ztransfer.license

import java.security.MessageDigest

private val ANDROID_ID_RE = Regex("^[0-9a-f]{16}$")
private val DEVICE_FINGERPRINT_RE = Regex("^[0-9a-f]{32}$")
private val INVALID_ANDROID_IDS = setOf(
    "0000000000000000",
    "9774d56d682e549c",
)

/**
 * Returns a usable ANDROID_ID, or null when the platform supplied a known
 * placeholder. Placeholder IDs are shared by unrelated phones and must never
 * be treated as a device identity.
 */
internal fun normalizedAndroidId(raw: String?): String? {
    val value = raw?.trim()?.lowercase() ?: return null
    return value.takeIf { ANDROID_ID_RE.matches(it) && it !in INVALID_ANDROID_IDS }
}

internal fun normalizedDeviceFingerprint(raw: String?): String? {
    val value = raw?.trim()?.lowercase() ?: return null
    return value.takeIf(DEVICE_FINGERPRINT_RE::matches)
}

/**
 * Keep an identity already pinned to this installation. During the first
 * upgrade to the pinned scheme, a server-signed token is the authoritative
 * migration source; only a brand-new/free installation falls back to the
 * current platform-derived fingerprint.
 */
internal fun selectDeviceFingerprint(
    pinnedFingerprint: String?,
    signedTokenFingerprint: String?,
    currentFingerprint: () -> String,
): String = normalizedDeviceFingerprint(pinnedFingerprint)
    ?: normalizedDeviceFingerprint(signedTokenFingerprint)
    ?: requireNotNull(normalizedDeviceFingerprint(currentFingerprint())) {
        "Current device fingerprint must be 32 lowercase hex characters"
    }

/**
 * Preserve the legacy fingerprint for valid ANDROID_ID values so existing
 * bindings keep working. Invalid values use a private per-install ID instead.
 */
internal fun computeDeviceFingerprint(
    androidId: String?,
    packageName: String,
    installId: String,
): String {
    val material = normalizedAndroidId(androidId)?.let { "$it:$packageName" }
        ?: "install-v2:$installId:$packageName"
    val digest = MessageDigest.getInstance("SHA-256").digest(material.toByteArray())
    return digest.take(16).joinToString("") { "%02x".format(it) }
}
