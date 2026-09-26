package com.ztransfer.diagnostics

import android.content.ContentResolver
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import com.ztransfer.BuildConfig
import kotlinx.coroutines.*
import java.io.OutputStream
import java.security.MessageDigest

/** Temporary USB investigation; enabled in Release too, removable after diagnosis. */
internal class UsbTransferDiagnostic private constructor(
    private val resolver: ContentResolver, private val report: Uri,
    private val text: StringBuilder, private val resumeOffset: Long,
    private val showReportFailure: suspend () -> Unit,
) {
    private val received = TransferByteDigest(resumeOffset)
    private var receivedRecorded = false
    private var lastSignature: String? = null
    private var reportFailureShown = false
    fun wrap(output: OutputStream): OutputStream = object : OutputStream() {
        override fun write(bytes: ByteArray, offset: Int, length: Int) {
            received.add(bytes, offset, length)
            output.write(bytes, offset, length)
        }
        override fun write(value: Int) = write(byteArrayOf(value.toByte()), 0, 1)
        override fun flush() = output.flush()
        override fun close() = output.close()
    }
    suspend fun note(message: String) {
        text.appendLine(message.replace('\r', ' '))
        persist()
    }
    suspend fun noDownload(reason: String) {
        receivedRecorded = true
        note("NO_USB_DOWNLOAD: $reason; no received-data hash is available")
    }
    suspend fun receivedComplete() {
        if (receivedRecorded) return
        receivedRecorded = true
        val summary = received.finish()
        lastSignature = summary.substringBefore(" zeroRanges=")
        note("received suffix[$resumeOffset..end]: $summary")
    }
    suspend fun inspect(stage: String, uri: Uri) = withContext(Dispatchers.IO) {
        receivedComplete()
        try {
            val digest = TransferByteDigest(resumeOffset)
            resolver.openInputStream(uri)?.use { input ->
                var skipped = 0L
                val buffer = ByteArray(256 * 1024)
                while (skipped < resumeOffset) {
                    currentCoroutineContext().ensureActive()
                    val count = input.read(buffer, 0, minOf(buffer.size.toLong(), resumeOffset-skipped).toInt())
                    check(count > 0) { "File shorter than resume offset" }
                    skipped += count
                }
                while (true) {
                    currentCoroutineContext().ensureActive()
                    val count = input.read(buffer)
                    if (count < 0) break
                    digest.add(buffer, 0, count)
                }
            } ?: error("Cannot open saved file")
            val summary = digest.finish()
            val signature = summary.substringBefore(" zeroRanges=")
            note("$stage: $summary matchesPrevious=${lastSignature?.let { it == signature } ?: "unknown"}")
            lastSignature = signature
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (failure: Exception) {
            lastSignature = null
            note("$stage readbackError=${failure.javaClass.simpleName}: ${failure.message}")
        }
    }
    suspend fun finish(outcome: String) = withContext(NonCancellable + Dispatchers.IO) {
        receivedComplete()
        note("end=$outcome time=${java.time.Instant.now()}")
    }
    private suspend fun persist() = withContext(Dispatchers.IO) {
        try {
            val body = text.toString()
            // Some document providers reject "wt". Our report only grows, so "w" is a
            // compatible overwrite fallback; readback below detects append/short-write behaviour.
            val output = try { resolver.openOutputStream(report, "wt") }
                catch (_: java.io.FileNotFoundException) { resolver.openOutputStream(report, "w") }
            output?.bufferedWriter(Charsets.UTF_8)?.use { it.write(body) }
                ?: error("Cannot open diagnostic TXT")
            val saved = resolver.openInputStream(report)?.bufferedReader(Charsets.UTF_8)?.use { it.readText() }
            check(saved == body) { "Diagnostic TXT readback differs from written text" }
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (failure: Exception) {
            android.util.Log.e("UsbTransferDiagnostic", "TXT write failed", failure)
            if (!reportFailureShown) {
                reportFailureShown = true
                showReportFailure()
            }
        }
    }
    companion object {
        suspend fun start(resolver: ContentResolver, parent: Uri, file: String, expected: Long,
            resumeOffset: Long, camera: String?, taskId: Long,
            showReportFailure: suspend () -> Unit): UsbTransferDiagnostic? = withContext(Dispatchers.IO) {
            try {
                val stamp = java.time.format.DateTimeFormatter.ofPattern("yyyyMMdd-HHmmss-SSS")
                    .format(java.time.LocalDateTime.now())
                val uri = DocumentsContract.createDocument(resolver, parent, "text/plain",
                    "ZTransfer_USB_${stamp}_${taskId}.txt") ?: error("Cannot create diagnostic TXT")
                UsbTransferDiagnostic(resolver, uri, StringBuilder().apply {
                    appendLine("ZTransfer USB transfer diagnostic v1")
                    appendLine("app=${BuildConfig.VERSION_NAME}(${BuildConfig.VERSION_CODE}) release=${!BuildConfig.DEBUG}")
                    appendLine("phone=${Build.MANUFACTURER} ${Build.MODEL} android=${Build.VERSION.RELEASE} sdk=${Build.VERSION.SDK_INT}")
                    appendLine("system=${Build.DISPLAY}")
                    appendLine("camera=$camera file=$file expected=$expected resumeOffset=$resumeOffset task=$taskId")
                    appendLine("Compare App received bytes, closed temporary file, final saved file.")
                    appendLine("On resume only the new suffix is compared; existing prefix is unverified.")
                    appendLine("Matching hashes do NOT prove camera-source correctness. Zero ranges are clues, not automatic corruption verdicts.")
                }, resumeOffset, showReportFailure).also { it.persist() }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: Exception) {
                android.util.Log.e("UsbTransferDiagnostic", "TXT creation failed", failure)
                showReportFailure()
                null
            }
        }
    }
}

/** Streaming summaries, without retaining image/video bytes. */
internal class TransferByteDigest(private val startOffset: Long = 0) {
    private val hash = MessageDigest.getInstance("SHA-256")
    private var bytes = 0L
    private var zeroStart = -1L
    private var zeroCount = 0
    private val ranges = ArrayList<String>()
    private var result: String? = null
    fun add(data: ByteArray, offset: Int, length: Int) {
        check(result == null)
        hash.update(data, offset, length)
        for (i in offset until offset+length) {
            if (data[i] == 0.toByte()) {
                if (zeroStart < 0) zeroStart = bytes + startOffset
            } else closeZeroRun()
            bytes++
        }
    }
    private fun closeZeroRun() {
        if (zeroStart >= 0 && bytes+startOffset-zeroStart >= 64*1024) {
            zeroCount++
            if (ranges.size < 32) ranges.add("[$zeroStart,${bytes+startOffset})")
        }
        zeroStart = -1L
    }
    fun finish(): String = result ?: run {
        closeZeroRun()
        "bytes=$bytes sha256=${hash.digest().joinToString("") { "%02x".format(it.toInt() and 255) }} zeroRanges=$ranges totalZeroRanges=$zeroCount"
            .also { result = it }
    }
}
