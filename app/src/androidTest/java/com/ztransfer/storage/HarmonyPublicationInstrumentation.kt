package com.ztransfer.storage

import android.app.Activity
import android.app.Instrumentation
import android.content.ContentProvider
import android.content.ContentResolver
import android.content.ContentValues
import android.content.pm.ProviderInfo
import android.database.Cursor
import android.graphics.Bitmap
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.os.ParcelFileDescriptor
import androidx.exifinterface.media.ExifInterface
import com.ztransfer.diagnostics.FingerprintResult
import com.ztransfer.diagnostics.TransferFingerprint
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileDescriptor
import java.io.FileNotFoundException

/** Synthetic files and a local provider; no camera or user photos are accessed. */
class HarmonyPublicationInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        start()
    }

    override fun onStart() {
        val result = Bundle()
        var code = Activity.RESULT_CANCELED
        val scratch = File(targetContext.cacheDir, "harmony-publication-fixture").apply { mkdirs() }
        try {
            runBlocking {
                val original = File(scratch, "source.jpg")
                val bitmap = Bitmap.createBitmap(64, 48, Bitmap.Config.ARGB_8888).apply {
                    eraseColor(Color.rgb(47, 104, 156))
                }
                original.outputStream().use { check(bitmap.compress(Bitmap.CompressFormat.JPEG, 95, it)) }
                bitmap.recycle()
                ExifInterface(original).apply {
                    setLatLong(31.25, 121.5)
                    saveAttributes()
                }
                val redacted = File(scratch, "read-view.jpg")
                original.copyTo(redacted, overwrite = true)
                ExifInterface(redacted).apply {
                    setLatLong(0.0, 0.0)
                    saveAttributes()
                }
                val jpegBytes = original.readBytes()
                val expectedJpeg = fingerprint(jpegBytes)
                check(expectedJpeg != fingerprint(redacted.readBytes()))
                val nef = File(scratch, "source.nef").apply {
                    // TIFF signature and deterministic payload, sufficient for a byte-preserving reader.
                    writeBytes(byteArrayOf(0x49, 0x49, 0x2a, 0) + ByteArray(600_000) { (it % 251).toByte() })
                }
                val nefBytes = nef.readBytes()
                val provider = PublicationFixtureProvider(original, redacted, nef)
                provider.attachInfo(targetContext, ProviderInfo().apply {
                    authority = AUTHORITY
                    exported = true
                    grantUriPermissions = true
                })
                val resolver = ContentResolver.wrap(provider)
                val jpgUri = Uri.parse("content://$AUTHORITY/source.jpg")
                val nefUri = Uri.parse("content://$AUTHORITY/source.nef")
                val selectedModes = mutableListOf<String>()
                suspend fun read(uri: Uri = jpgUri): FingerprintResult =
                    fingerprintHarmonyPublication(resolver, uri) { selectedModes += it }
                fun reset() {
                    provider.assertClosed()
                    provider.reset()
                    selectedModes.clear()
                }
                fun checkModes(expected: List<String>, opened: List<String> = expected) {
                    check(selectedModes == expected) { "Selected modes: $selectedModes" }
                    check(provider.openedModes == opened) { "Provider opens: ${provider.openedModes}" }
                    provider.assertClosed()
                }

                // Establish the original bug: the provider's image read view differs only in EXIF.
                resolver.openInputStream(jpgUri)!!.use { check(fingerprint(it.readBytes()) != expectedJpeg) }
                reset()
                check(read() == expectedJpeg)
                checkModes(listOf("rw"))
                check(original.readBytes().contentEquals(jpegBytes)) { "Verification changed/truncated JPEG" }

                reset()
                check(read(nefUri) == fingerprint(nefBytes))
                checkModes(listOf("rw"))
                check(nef.readBytes().contentEquals(nefBytes)) { "Verification changed/truncated NEF" }

                // Unsupported or null read/write descriptors may use the original read-only path.
                for (nullDescriptor in listOf(false, true)) {
                    reset()
                    provider.unsupportedReadWrite = !nullDescriptor
                    provider.nullReadWrite = nullDescriptor
                    provider.redactJpegRead = false
                    check(read() == expectedJpeg)
                    checkModes(listOf("r"), listOf("rw", "r"))
                }

                // A provider that still redacts the fallback must not be considered verified.
                reset()
                provider.unsupportedReadWrite = true
                check(read() != expectedJpeg)
                checkModes(listOf("r"), listOf("rw", "r"))

                // Same-sized real corruption remains detectable; there is no second read strategy.
                reset()
                val damaged = jpegBytes.copyOf().apply { this[lastIndex - 3] = (this[lastIndex - 3].toInt() xor 1).toByte() }
                original.writeBytes(damaged)
                val damagedResult = read()
                check(damagedResult.bytes == expectedJpeg.bytes && damagedResult.sha256 != expectedJpeg.sha256)
                checkModes(listOf("rw"))
                check(original.readBytes().contentEquals(damaged))
                original.writeBytes(jpegBytes)

                reset()
                provider.failRead = true
                check(runCatching { read() }.isFailure) { "Read error was swallowed" }
                checkModes(listOf("rw"))

                reset()
                provider.unsupportedReadWrite = true
                provider.failReadOpen = true
                check(runCatching { read() }.exceptionOrNull() is FileNotFoundException)
                checkModes(emptyList(), listOf("rw", "r"))

                // Cancellation while opening must not fall back; cancellation during reading closes FD.
                reset()
                provider.cancelReadWriteOpen = true
                check(runCatching { read() }.exceptionOrNull() is CancellationException)
                checkModes(emptyList(), listOf("rw"))
                reset()
                val readJob = Job()
                val cancelled = runCatching {
                    withContext(readJob) {
                        fingerprintHarmonyPublication(resolver, jpgUri) {
                            selectedModes += it
                            readJob.cancel()
                        }
                    }
                }.exceptionOrNull()
                check(cancelled is CancellationException) { "Read cancellation was swallowed: $cancelled" }
                checkModes(listOf("rw"))
                check(original.readBytes().contentEquals(jpegBytes))
                check(nef.readBytes().contentEquals(nefBytes))
                result.putString("result", "PASS: JPG EXIF read view; NEF; rw unsupported/null fallback; strict full-file corruption/redaction rejection; read/open failures; cancellation; descriptor cleanup; unchanged files")
            }
            code = Activity.RESULT_OK
        } catch (failure: Throwable) {
            result.putString("failure", failure.stackTraceToString())
        } finally {
            scratch.deleteRecursively()
        }
        finish(code, result)
    }

    private fun fingerprint(bytes: ByteArray): FingerprintResult =
        TransferFingerprint().apply { update(bytes, 0, bytes.size) }.finish()

    private companion object {
        const val AUTHORITY = "com.ztransfer.debug.test.harmonypublication"
    }
}

private class PublicationFixtureProvider(
    private val originalJpeg: File,
    private val redactedJpeg: File,
    private val nef: File,
) : ContentProvider() {
    var unsupportedReadWrite = false
    var nullReadWrite = false
    var redactJpegRead = true
    var failRead = false
    var failReadOpen = false
    var cancelReadWriteOpen = false
    val openedModes = mutableListOf<String>()
    private val descriptors = mutableListOf<FileDescriptor>()

    fun reset() {
        unsupportedReadWrite = false
        nullReadWrite = false
        redactJpegRead = true
        failRead = false
        failReadOpen = false
        cancelReadWriteOpen = false
        openedModes.clear()
        descriptors.clear()
    }

    fun assertClosed() {
        check(descriptors.none { it.valid() }) { "Provider descriptor leaked" }
    }

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor? {
        openedModes += mode
        if (mode == "rw") {
            if (cancelReadWriteOpen) throw CancellationException("Injected open cancellation")
            if (unsupportedReadWrite) throw UnsupportedOperationException("Injected rw limitation")
            if (nullReadWrite) return null
        } else if (failReadOpen) {
            throw FileNotFoundException("Injected read-open failure")
        }
        val file = when (uri.lastPathSegment) {
            "source.jpg" -> if (mode == "r" && redactJpegRead) redactedJpeg else originalJpeg
            "source.nef" -> nef
            else -> throw FileNotFoundException("Unknown fixture")
        }
        // A directory descriptor opens successfully but fails when read, testing post-open errors.
        val descriptor = if (failRead) {
            ParcelFileDescriptor.open(checkNotNull(file.parentFile), ParcelFileDescriptor.MODE_READ_ONLY)
        } else {
            ParcelFileDescriptor.open(file, ParcelFileDescriptor.parseMode(mode))
        }
        descriptors += descriptor.fileDescriptor
        return descriptor
    }

    override fun onCreate() = true
    override fun getType(uri: Uri) = if (uri.lastPathSegment?.endsWith(".nef") == true) "image/x-nikon-nef" else "image/jpeg"
    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = 0
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = 0
}
