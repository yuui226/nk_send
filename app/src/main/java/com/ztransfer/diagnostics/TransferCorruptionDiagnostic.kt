package com.ztransfer.diagnostics

import android.content.ContentResolver
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import com.ztransfer.BuildConfig
import com.ztransfer.protocol.NikonCamera
import java.io.BufferedWriter
import java.io.File
import java.io.FileOutputStream
import java.io.OutputStream
import java.io.OutputStreamWriter
import java.time.Instant
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

/**
 * One-shot diagnostic for a reported corrupted original. It is compiled into the
 * special investigation release only. The normal build keeps this completely off.
 *
 * The report deliberately separates four observations:
 * R = bytes delivered by the camera protocol before the destination write;
 * T = the temporary provider document read back after the stream is closed;
 * F = the published document read back after rename/copy;
 * C = a later camera reread, when the diagnostic release can keep the connection.
 *
 * The private append log is authoritative while transferring. The SAF report is
 * mirrored only at session start/checkpoints/end so a provider problem is not
 * amplified by rewriting a report for every packet.
 */
internal class TransferCorruptionDiagnostic private constructor(
    private val resolver: ContentResolver,
    private val reportUri: Uri?,
    private val privateFile: File,
    private val text: StringBuilder,
) {
    private val lock = Any()
    private var writer: BufferedWriter? = null
    private var fileCount = 0
    private val rereadTargets = ArrayList<SourceRereadTarget>()
    private val publishedTargets = ArrayList<PublishedTarget>()
    private val receivedByTarget = HashMap<String, FingerprintResult>()

    data class SourceRereadTarget(
        val name: String,
        val handle: Int,
        val expectedBytes: Long,
        val video: Boolean,
    )

    data class PublishedTarget(
        val name: String,
        val uri: Uri,
    )

    data class UriFingerprint(
        val actualSize: Long?,
        val fingerprint: FingerprintResult?,
        val error: String? = null,
    )

    fun append(message: String) {
        synchronized(lock) {
            text.appendLine(message.replace('\r', ' '))
            try {
                if (writer == null) {
                    privateFile.parentFile?.mkdirs()
                    writer = BufferedWriter(
                        OutputStreamWriter(FileOutputStream(privateFile, true), Charsets.UTF_8),
                        32 * 1024,
                    )
                }
                writer!!.apply {
                    write(message.replace('\r', ' '))
                    newLine()
                    flush()
                }
            } catch (failure: Exception) {
                // Diagnostics must never change transfer success/failure.
                android.util.Log.w("ZTransferDiagnostic", "private log write failed", failure)
            }
        }
    }

    fun appendProtocol(message: String) = append("P $message")

    fun noteFileStart(
        name: String,
        handle: Int,
        expectedBytes: Long,
        resumeOffset: Long,
        video: Boolean,
        transport: String,
    ) {
        append(
            "FILE_START name=$name handle=0x${handle.toUInt().toString(16)} " +
                "expected=$expectedBytes resume=$resumeOffset video=$video transport=$transport",
        )
    }

    fun noteFileFailure(name: String, error: Throwable) {
        append("FILE_FAIL name=$name type=${error.javaClass.simpleName} message=${error.message.orEmpty()}")
    }

    fun noteVerificationFailure(
        name: String,
        reason: String,
        received: FingerprintResult?,
        temporary: UriFingerprint?,
        final: FingerprintResult?,
    ) {
        append("VERIFY_FAIL name=$name reason=${reason.replace(' ', '_')}")
        append("R received=${received.asText()}")
        append("T temporary=${temporary.asText()}")
        append("F final=${final.asText()}")
    }

    fun noteFileResult(
        name: String,
        handle: Int,
        expectedBytes: Long,
        resumeOffset: Long,
        video: Boolean,
        saveMode: String,
        received: FingerprintResult?,
        temporary: UriFingerprint?,
        final: UriFingerprint?,
        finalUri: Uri?,
        elapsedMs: Long?,
    ) {
        append(
            "FILE_RESULT name=$name handle=0x${handle.toUInt().toString(16)} " +
                "expected=$expectedBytes resume=$resumeOffset video=$video mode=$saveMode " +
                "elapsedMs=${elapsedMs ?: -1}",
        )
        append("R received=${received.asText()}")
        append("T temporary=${temporary.asText()}")
        append("F final=${final.asText()}")
        if (received != null && temporary?.fingerprint != null) {
            append("R_vs_T=${fingerprintDifference(received, temporary.fingerprint)}")
        }
        if (temporary?.fingerprint != null && final?.fingerprint != null) {
            append("T_vs_F=${fingerprintDifference(temporary.fingerprint, final.fingerprint)}")
        }
        if (received != null && final?.fingerprint != null) {
            append("R_vs_F=${fingerprintDifference(received, final.fingerprint)}")
        }
        received?.let { receivedByTarget[targetKey(name, handle)] = it }
        fileCount++
        if (fileCount % CHECKPOINT_EVERY_FILES == 0) {
            append("CHECKPOINT files=$fileCount")
            mirrorBestEffort()
        }
        rereadTargets += SourceRereadTarget(name, handle, expectedBytes, video)
        finalUri?.let { publishedTargets += PublishedTarget(name, it) }
    }

    /** Re-reads the published files after the queue has drained, catching delayed provider writes. */
    suspend fun rereadPublished() {
        val targets = synchronized(lock) { publishedTargets.toList() }
        if (targets.isEmpty()) {
            append("L phase=skipped reason=no-published-files")
            return
        }
        append("L phase=start files=${targets.size}")
        for (target in targets) {
            currentCoroutineContext().ensureActive()
            val started = android.os.SystemClock.elapsedRealtime()
            val result = readUri(target.uri)
            append(
                "L final name=${target.name} elapsedMs=${android.os.SystemClock.elapsedRealtime() - started} " +
                    result.asText(),
            )
        }
        append("L phase=end")
    }

    suspend fun readUri(uri: Uri): UriFingerprint = withContext(Dispatchers.IO) {
        try {
            val fingerprint = TransferFingerprint()
            resolver.openInputStream(uri)?.use { input ->
                val buffer = ByteArray(256 * 1024)
                while (true) {
                    currentCoroutineContext().ensureActive()
                    val count = input.read(buffer)
                    if (count < 0) break
                    check(count > 0) { "provider returned an empty read" }
                    fingerprint.update(buffer, 0, count)
                }
            } ?: error("provider returned null input stream")
            UriFingerprint(
                actualSize = querySize(uri),
                fingerprint = fingerprint.finish(),
            )
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            UriFingerprint(null, null, "${failure.javaClass.simpleName}: ${failure.message}")
        }
    }

    /** Read a private staging file using the same bounded fingerprint format as SAF reads. */
    suspend fun readFile(file: File): UriFingerprint = withContext(Dispatchers.IO) {
        try {
            val fingerprint = TransferFingerprint()
            file.inputStream().buffered(256 * 1024).use { input ->
                val buffer = ByteArray(256 * 1024)
                while (true) {
                    currentCoroutineContext().ensureActive()
                    val count = input.read(buffer)
                    if (count < 0) break
                    check(count > 0) { "staging file returned an empty read" }
                    fingerprint.update(buffer, 0, count)
                }
            }
            UriFingerprint(file.length(), fingerprint.finish())
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            UriFingerprint(null, null, "${failure.javaClass.simpleName}: ${failure.message}")
        }
    }

    /** Read an existing resume prefix into the same whole-file fingerprint. */
    suspend fun readPrefix(uri: Uri, count: Long, fingerprint: TransferFingerprint) =
        withContext(Dispatchers.IO) {
            if (count <= 0L) return@withContext
            resolver.openInputStream(uri)?.use { input ->
                val buffer = ByteArray(256 * 1024)
                var remaining = count
                while (remaining > 0) {
                    currentCoroutineContext().ensureActive()
                    val want = minOf(buffer.size.toLong(), remaining).toInt()
                    val read = input.read(buffer, 0, want)
                    check(read > 0) { "resume prefix shorter than expected" }
                    fingerprint.update(buffer, 0, read)
                    remaining -= read
                }
            } ?: error("provider returned null input stream")
        }

    /**
     * Re-read each successful source in the diagnostic release. This is intentionally
     * outside the normal build: it costs another camera read, but gives a single
     * investigation run a useful C comparison instead of guessing from R/T/F alone.
     */
    suspend fun rereadSources(camera: NikonCamera?) {
        if (camera == null || rereadTargets.isEmpty()) {
            append("C phase=skipped reason=${if (camera == null) "camera-unavailable" else "no-successful-files"}")
            return
        }
        append("C phase=start files=${rereadTargets.size}")
        for (target in rereadTargets) {
            currentCoroutineContext().ensureActive()
            val fingerprint = TransferFingerprint()
            val started = android.os.SystemClock.elapsedRealtime()
            try {
                val result = camera.downloadToFile(
                    handle = target.handle,
                    output = NullOutputStream,
                    resumeOffset = 0L,
                    totalSize = target.expectedBytes,
                    preferHighThroughputAtStart = { true },
                    captureHeader = false,
                    videoTransfer = target.video,
                    trace = { message -> appendProtocol("C $message") },
                    diagnosticReferenceRead = true,
                    onBytesReceived = { bytes, offset, count ->
                        fingerprint.update(bytes, offset, count)
                    },
                )
                val source = fingerprint.finish()
                append(
                    "C source name=${target.name} handle=0x${target.handle.toUInt().toString(16)} " +
                        "ok=${result.isSuccess} elapsedMs=${android.os.SystemClock.elapsedRealtime() - started} " +
                        "${source.asText()} " +
                        "C_vs_R=${receivedByTarget[targetKey(target.name, target.handle)]?.let {
                            fingerprintDifference(it, source)
                        } ?: "unavailable"}",
                )
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Exception) {
                append(
                    "C source name=${target.name} handle=0x${target.handle.toUInt().toString(16)} " +
                        "error=${failure.javaClass.simpleName}: ${failure.message}",
                )
            }
        }
        append("C phase=end")
    }

    suspend fun finish(outcome: String) = withContext(NonCancellable + Dispatchers.IO) {
        synchronized(lock) {
            try { writer?.flush(); writer?.close() } catch (_: Exception) {}
            writer = null
        }
        append("END outcome=$outcome files=$fileCount time=${Instant.now()}")
        mirrorBestEffort()
    }

    private fun querySize(uri: Uri): Long? = try {
        resolver.query(
            uri,
            arrayOf(DocumentsContract.Document.COLUMN_SIZE),
            null,
            null,
            null,
        )?.use { cursor ->
            val index = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_SIZE)
            if (index >= 0 && cursor.moveToFirst() && !cursor.isNull(index)) cursor.getLong(index) else null
        }
    } catch (_: Exception) {
        null
    }

    private fun targetKey(name: String, handle: Int): String = "$handle\u0000$name"

    private fun mirrorBestEffort() {
        val report = reportUri ?: return
        val body = synchronized(lock) { text.toString() }
        try {
            // Some DocumentsProviders reject truncating "wt" even though they support normal
            // writable streams. Retry all provider exceptions with the portable "w" mode.
            val output = try {
                resolver.openOutputStream(report, "wt")
            } catch (_: Exception) {
                resolver.openOutputStream(report, "w")
            }
            output?.bufferedWriter(Charsets.UTF_8)?.use { it.write(body) }
        } catch (failure: Exception) {
            android.util.Log.w("ZTransferDiagnostic", "SAF report mirror failed", failure)
        }
    }

    companion object {
        private const val CHECKPOINT_EVERY_FILES = 8
        private val NullOutputStream = object : OutputStream() {
            override fun write(value: Int) = Unit
            override fun write(bytes: ByteArray, offset: Int, count: Int) = Unit
        }

        suspend fun start(
            resolver: ContentResolver,
            parent: Uri,
            camera: NikonCamera?,
            filesDir: File,
        ): TransferCorruptionDiagnostic? = withContext(Dispatchers.IO) {
            if (!BuildConfig.TRANSFER_CORRUPTION_DIAGNOSTIC) return@withContext null
            val stamp = java.time.format.DateTimeFormatter.ofPattern("yyyyMMdd-HHmmss-SSS")
                .format(java.time.LocalDateTime.now())
            val privateDir = File(filesDir, "transfer-diagnostics").apply { mkdirs() }
            val privateFile = File(privateDir, "ZTransfer_corruption_$stamp.txt")
            var reportUri: Uri? = null
            try {
                reportUri = DocumentsContract.createDocument(
                    resolver,
                    parent,
                    "text/plain",
                    "ZTransfer_corruption_$stamp.txt",
                )
            } catch (_: Exception) {}
            val text = StringBuilder()
            val diagnostic = TransferCorruptionDiagnostic(resolver, reportUri, privateFile, text)
            diagnostic.append("ZTransfer corruption diagnostic v3")
            diagnostic.append("app=${BuildConfig.VERSION_NAME}(${BuildConfig.VERSION_CODE}) release=${!BuildConfig.DEBUG}")
            diagnostic.append("phone=${Build.MANUFACTURER} ${Build.MODEL} android=${Build.VERSION.RELEASE} sdk=${Build.VERSION.SDK_INT}")
            diagnostic.append("build=${Build.DISPLAY}")
            diagnostic.append("camera=${camera?.transferDiagnosticDescription() ?: "unavailable"}")
            diagnostic.append("targetAuthority=${parent.authority.orEmpty()} targetScheme=${parent.scheme.orEmpty()}")
            diagnostic.append("reportUri=${reportUri ?: "private-only"}")
            diagnostic.append("stages=R(received) T(temp-readback) F(final-readback) L(queue-end-readback) C(camera-reread)")
            diagnostic.append("hash=SHA-256 whole-file plus fixed 4MiB segment hashes; no media bytes retained")
            diagnostic.mirrorBestEffort()
            diagnostic
        }
    }
}

private fun FingerprintResult?.asText(): String = when (this) {
    null -> "unavailable"
    else -> "bytes=$bytes sha256=$sha256 segments=${segments.size} truncated=$segmentsTruncated"
}

private fun TransferCorruptionDiagnostic.UriFingerprint?.asText(): String = when (this) {
    null -> "unavailable"
    else -> "size=${actualSize ?: "unknown"} ${fingerprint.asText()}" +
        (error?.let { " error=${it.replace(' ', '_')}" } ?: "")
}
