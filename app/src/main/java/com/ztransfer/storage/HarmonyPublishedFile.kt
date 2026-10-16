package com.ztransfer.storage

import android.content.ContentResolver
import android.net.Uri
import android.os.ParcelFileDescriptor
import com.ztransfer.diagnostics.FingerprintResult
import com.ztransfer.diagnostics.TransferFingerprint
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

/** Only for an app-created publication with the destination's read/write URI grant. */
internal suspend fun fingerprintHarmonyPublication(
    resolver: ContentResolver,
    uri: Uri,
    onReadMode: (String) -> Unit = {},
): FingerprintResult = withContext(Dispatchers.IO) {
    currentCoroutineContext().ensureActive()
    // Some providers route read-only image opens through a transformed media view.
    // "rw" is non-truncating; we only read from this descriptor, after the writer closes.
    val descriptor = try {
        resolver.openFileDescriptor(uri, "rw")
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (_: Exception) {
        currentCoroutineContext().ensureActive()
        null
    }
    val input = if (descriptor != null) {
        ParcelFileDescriptor.AutoCloseInputStream(descriptor)
    } else {
        resolver.openInputStream(uri) ?: error("provider returned null input stream")
    }
    input.use {
        onReadMode(if (descriptor != null) "rw" else "r")
        val fingerprint = TransferFingerprint()
        val buffer = ByteArray(256 * 1024)
        while (true) {
            currentCoroutineContext().ensureActive()
            val count = it.read(buffer)
            if (count < 0) break
            check(count > 0) { "provider returned an empty read" }
            fingerprint.update(buffer, 0, count)
        }
        fingerprint.finish()
    }
}
