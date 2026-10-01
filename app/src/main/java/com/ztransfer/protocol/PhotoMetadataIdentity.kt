package com.ztransfer.protocol

/** Known physical identities survive reconnects; model-only fallback is connection-local. */
internal fun scopedPhotoMetadataIdentity(cacheIdentity: String, sessionIdentity: String): String =
    if (cacheIdentity.substringAfterLast('\u0000') == "unknown-device")
        "$cacheIdentity\u0000session:$sessionIdentity"
    else cacheIdentity

/** A reconnected body's handle alone is not sufficient to identify the original photo. */
internal fun samePhotoMetadataSource(expected: NikonCamera.FileInfo, actual: NikonCamera.FileInfo?): Boolean =
    actual != null && expected.handle == actual.handle && expected.size > 0 &&
        expected.size == actual.size && expected.fileName == actual.fileName &&
        !expected.captureDate.isNullOrBlank() && expected.captureDate == actual.captureDate
