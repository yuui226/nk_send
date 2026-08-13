package com.ztransfer.license

import java.security.MessageDigest

private val ANDROID_ID_RE = Regex("^[0-9a-f]{16}$")
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
