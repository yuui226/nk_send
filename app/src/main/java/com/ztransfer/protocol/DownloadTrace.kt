package com.ztransfer.protocol

import com.ztransfer.BuildConfig

/**
 * Bounded, passive transfer tracing.  The callback is deliberately a plain public function type
 * at the NikonCamera boundary; this implementation remains internal so callers cannot depend on
 * the transport's bookkeeping types.
 *
 * Nothing is retained when diagnostics are disabled.  Packet observations are aggregated and are
 * emitted with the transaction summary rather than once per packet.
 */
internal class DownloadTrace(callback: ((String) -> Unit)?) {
    private val callback: ((String) -> Unit)? =
        callback?.takeIf { BuildConfig.TRANSFER_DIAGNOSTICS }

    val enabled: Boolean get() = callback != null

    private var active: Transaction? = null

    private data class Transaction(
        val transport: String,
        val operation: Int,
        val transactionId: Int,
        val offset: Long,
        val requestBytes: Int,
        val startedAtMs: Long,
        var declared: Long = -1L,
        var wifiPackets: Int = 0,
        var wifiPayloadBytes: Long = 0L,
        var wifiTidMismatches: Int = 0,
        var wifiStarts: Int = 0,
        var wifiDataPacketsObserved: Int = 0,
        var wifiDataBeforeStart: Int = 0,
        var wifiDuplicateStarts: Int = 0,
        var wifiStartAfterData: Int = 0,
        var wifiStartAfterEnd: Int = 0,
        var wifiDataAfterEnd: Int = 0,
        var wifiEndsWithoutStart: Int = 0,
        var wifiEnded: Boolean = false,
        var usbHeaders: Int = 0,
        var usbHeaderTidMismatches: Int = 0,
        var usbResponseHeaders: Int = 0,
        var usbFirstHeader: String? = null,
        var usbResponseHeader: String? = null,
    )

    fun strategy(transport: String, mode: String, chunkSize: Long?) {
        if (!enabled) return
        emit(
            "download strategy transport=$transport mode=$mode" +
                (chunkSize?.let { " chunkBytes=$it" } ?: ""),
        )
    }

    fun start(transport: String, operation: Int, transactionId: Int, offset: Long, requestBytes: Int) {
        if (!enabled) return
        // A previous transaction can only be left active after an exceptional path.  Keep the
        // trace useful without affecting the transfer itself.
        active?.let { previous ->
            emit("download transaction abandoned op=0x${previous.operation.toString(16)} tid=${previous.transactionId}")
        }
        active = Transaction(
            transport = transport,
            operation = operation,
            transactionId = transactionId,
            offset = offset,
            requestBytes = requestBytes,
            startedAtMs = android.os.SystemClock.elapsedRealtime(),
        )
        emit(
            "download transaction start transport=$transport " +
                "op=0x${operation.toString(16)} tid=$transactionId offset=$offset requestBytes=$requestBytes",
        )
    }

    /** Observe one PTP/IP data packet without emitting a line for it. */
    fun wifiPacket(type: Int, packetTransactionId: Int?, payloadBytes: Int, declared: Long? = null) {
        val tx = active ?: return
        if (!enabled || tx.transport != "wifi") return
        tx.wifiPackets++
        tx.wifiPayloadBytes += payloadBytes.toLong()
        if (packetTransactionId == null || packetTransactionId != tx.transactionId) tx.wifiTidMismatches++
        when (type) {
            PtpConstants.START_DATA_PACKET -> {
                tx.wifiStarts++
                if (tx.wifiStarts > 1) tx.wifiDuplicateStarts++
                if (tx.wifiDataPacketsObserved > 0) tx.wifiStartAfterData++
                if (tx.wifiEnded) tx.wifiStartAfterEnd++
                tx.declared = declared ?: tx.declared
            }
            PtpConstants.DATA_PACKET -> {
                tx.wifiDataPacketsObserved++
                if (tx.wifiStarts == 0) tx.wifiDataBeforeStart++
                if (tx.wifiEnded) tx.wifiDataAfterEnd++
            }
            PtpConstants.END_DATA_PACKET -> {
                tx.wifiDataPacketsObserved++
                if (tx.wifiStarts == 0) tx.wifiEndsWithoutStart++
                if (tx.wifiEnded) tx.wifiDataAfterEnd++
                tx.wifiEnded = true
            }
        }
    }

    /** Observe the PTP/IP response payload (u16 response code + u32 transaction id). */
    fun wifiResponse(packetTransactionId: Int?, responseCode: Int, payloadBytes: Int) {
        val tx = active ?: return
        if (!enabled || tx.transport != "wifi") return
        if (packetTransactionId == null || packetTransactionId != tx.transactionId) {
            tx.wifiTidMismatches++
        }
        if (responseCode != PtpConstants.RESPONSE_OK) {
            // The response code is already reported by the transaction summary; keep this
            // method passive and bounded rather than adding another line per packet.
        }
    }

    fun usbHeader(type: Int, code: Int, transactionId: Int, declared: Long) {
        val tx = active ?: return
        if (!enabled || tx.transport != "usb") return
        tx.usbHeaders++
        if (transactionId != tx.transactionId) tx.usbHeaderTidMismatches++
        tx.declared = declared
        val header = "type=$type code=0x${code.toString(16)} tid=$transactionId declared=$declared"
        if (tx.usbFirstHeader == null) tx.usbFirstHeader = header
        if (type == 3) {
            tx.usbResponseHeaders++
            tx.usbResponseHeader = header
        }
    }

    fun end(response: Int, expected: Long, received: Long, usb: UsbReadTraceStats? = null) {
        val tx = active ?: return
        active = null
        if (!enabled) return
        val elapsed = (android.os.SystemClock.elapsedRealtime() - tx.startedAtMs).coerceAtLeast(0L)
        val line = buildString {
            append("download transaction end transport=${tx.transport}")
            append(" op=0x${tx.operation.toString(16)} tid=${tx.transactionId}")
            append(" response=0x${response.toString(16)} expected=$expected received=$received")
            append(" elapsedMs=$elapsed")
            if (tx.transport == "wifi") {
                append(" packets=${tx.wifiPackets} starts=${tx.wifiStarts}")
                append(" packetBytes=${tx.wifiPayloadBytes}")
                if (tx.wifiTidMismatches > 0) append(" tidMismatches=${tx.wifiTidMismatches}")
                if (tx.wifiDataBeforeStart > 0) append(" dataBeforeStart=${tx.wifiDataBeforeStart}")
                if (tx.wifiDuplicateStarts > 0) append(" duplicateStarts=${tx.wifiDuplicateStarts}")
                if (tx.wifiStartAfterData > 0) append(" startAfterData=${tx.wifiStartAfterData}")
                if (tx.wifiStartAfterEnd > 0) append(" startAfterEnd=${tx.wifiStartAfterEnd}")
                if (tx.wifiEndsWithoutStart > 0) append(" endBeforeStart=${tx.wifiEndsWithoutStart}")
                if (tx.wifiDataAfterEnd > 0) append(" dataAfterEnd=${tx.wifiDataAfterEnd}")
            } else {
                append(" headers=${tx.usbHeaders}")
                tx.usbFirstHeader?.let { append(" header={$it}") }
                if (tx.usbHeaderTidMismatches > 0) append(" headerTidMismatches=${tx.usbHeaderTidMismatches}")
                append(" responseHeaders=${tx.usbResponseHeaders}")
                tx.usbResponseHeader?.let { append(" response={$it}") }
                usb?.let {
                    append(" usbReadRequests=${it.readRequests}")
                    append(" usbReadBytes=${it.readBytes}")
                    append(" usbZeroPackets=${it.zeroPackets}")
                    append(" usbTimeouts=${it.timeouts}")
                }
            }
        }
        emit(line)
    }

    fun error(context: String, error: Throwable) {
        if (!enabled) return
        val tx = active
        emit(
            "download error context=$context" +
                (tx?.let { " transport=${it.transport} op=0x${it.operation.toString(16)} tid=${it.transactionId} offset=${it.offset}" }
                    ?: "") +
                " type=${error.javaClass.simpleName} message=${error.message.orEmpty()}",
        )
        active = null
    }

    private fun emit(message: String) {
        try {
            callback?.invoke(message)
        } catch (_: Throwable) {
            // Diagnostics must never change transfer, cancellation, or connection semantics.
        }
    }
}

internal data class UsbReadTraceStats(
    val readRequests: Long,
    val readBytes: Long,
    val zeroPackets: Long,
    val timeouts: Long,
)
