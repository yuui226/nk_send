package com.ztransfer.protocol

import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/** All commands here are data-in reads. Never send an NP3 as a 90CD payload. */
internal suspend fun NikonCamera.probePictureControl(
    isCurrentCamera: () -> Boolean,
    log: (String) -> Unit,
    checkpoint: suspend (Int) -> Unit = {},
) {
    val info = cachedDeviceInfo
    log("camera=$deviceModel firmware=${info?.deviceVersion} transport=$connectionType")
    if (info == null) {
        log("INCOMPLETE: DeviceInfo unavailable; no requests sent")
        return
    }
    runPictureControlProbe(info, log, checkpoint) { code, params ->
        currentCoroutineContext().ensureActive()
        check(isCurrentCamera()) { "Camera session changed or camera became busy" }
        focusMutex.withLock {
            withCameraTransaction(CameraRequestKind.INTERACTIVE, "PICTURE_CONTROL_PROBE") {
                check(isCurrentCamera()) { "Camera session changed or camera became busy" }
                // Drain each response before cancellation can release the camera gate.
                withContext(Dispatchers.IO + NonCancellable) {
                    val timeout = setCommandReadTimeout(5_000)
                    try {
                        sendCmd(code, *params)
                        recvRespWithPayload()
                    } catch (error: IOException) {
                        abortProtocolTransport()
                        throw error
                    } finally {
                        restoreCommandReadTimeout(timeout)
                    }
                }
            }
        }
    }
}

/**
 * Bounded read plan, separated from the transport for replay tests.
 * Known opcode/property IDs: https://github.com/gphoto/libgphoto2/blob/master/camlibs/ptp2/ptp.h
 * GetPicCtrlData(item, 0), C1..C9=201..209: digiCamControl NikonBase.cs.
 * Other raw arguments are experimental; their meaning is NOT established.
 */
internal suspend fun runPictureControlProbe(
    info: LabDeviceInfo,
    log: (String) -> Unit,
    checkpoint: suspend (Int) -> Unit = {},
    nowNanos: () -> Long = System::nanoTime,
    transact: suspend (Int, IntArray) -> Pair<Int, ByteArray?>,
) {
    val started = nowNanos()
    val payloads = PictureControlProbePayloads(log)
    var requests = 0
    var errors = 0
    var skipped = 0
    val unsupportedOperations = mutableSetOf<Int>()
    fun codes(label: String, values: Collection<Int>) = formatProbeCodeLines(label, values).forEach(log)
    log("read-only; fixed target C9=209; NP3 write format NOT confirmed")
    log("limits: 512 requests, 180 seconds between requests; in-flight responses are drained before stopping")
    codes("DeviceInfo.operations", info.operations)
    codes("DeviceInfo.events", info.events)
    codes("DeviceInfo.properties", info.props)
    log("vendorExtension id=${info.vendorExtId} version=${info.vendorExtVersion}")

    suspend fun read(label: String, code: Int, vararg params: Int): Pair<Int, ByteArray?> {
        // A future plan edit must not accidentally introduce a mutating opcode.
        require(code in setOf(0x1014, 0x1015, 0x90CA, 0x9439, 0x90CC, 0x90CF))
        if (code in unsupportedOperations) {
            skipped++
            log("SKIP $label: operation explicitly unsupported")
            return 0x2005 to null
        }
        var attempt = 0
        while (true) {
            currentCoroutineContext().ensureActive()
            check(requests < 512 && nowNanos() - started < 180_000_000_000L) {
                "INCOMPLETE: collection limit reached after $requests requests"
            }
            val id = "r%03d".format(++requests)
            log("$id request $label op=0x%04X params=%s".format(code, params.joinToString()))
            // Persist before transmission, so an interrupted request remains identifiable.
            checkpoint(requests)
            val (rc, data) = transact(code, params)
            log("$id response rc=0x%04X bytes=%d".format(rc, data?.size ?: 0))
            payloads.record(id, data)
            if (rc != 0x2001) errors++
            if (rc == 0x2005) unsupportedOperations += code
            checkpoint(requests)
            // Keep the full response already received, then stop before requesting more.
            check(payloads.uniqueBytes <= 2 * 1024 * 1024) {
                "INCOMPLETE: full received data saved; 2 MiB unique payload budget reached"
            }
            if (rc != 0x2019 || attempt++ >= 2) return rc to data
            log("$id camera busy; retrying this read")
            delay(150)
        }
    }

    val properties = info.props.toMutableSet()
    for ((op, args) in listOf(0x90CA to intArrayOf(), 0x9439 to intArrayOf(0x0D))) {
        if (op !in info.operations) continue
        val (rc, data) = read("vendor properties", op, *args)
        if (rc == 0x2001 && data != null) {
            runCatching { parsePictureControlVendorCodes(data, if (op == 0x90CA) 2 else 4) }
                .onSuccess { properties += it; codes("vendor properties 0x%04X".format(op), it) }
                .onFailure { log("!! vendor property list parse: ${it.message}; raw retained") }
        }
    }
    val items = sortedSetOf<Int>()
    val initialValues = mutableMapOf<Int, ByteArray>()
    // D237 is movie selection. D241 is a wireless adapter string, NOT Picture Control.
    val coreProperties = linkedMapOf(
        0xD200 to "photo selection", 0xD201 to "photo change item",
        0xD237 to "movie selection", 0xD238 to "movie change item",
    )
    val relatedProperties = linkedMapOf(
        0xD1A6 to "live-view selector", 0x1D00B to "view-mode Picture Control",
        0x1D01C to "tone mode", 0x1D01D to "HLG Picture Control",
        0x1D000 to "movie ProRes tone mode", 0x1D001 to "movie H265 tone mode",
        0x1D028 to "movie NRAW tone mode",
    ).filterKeys { it in properties }
    // Nikon vendor properties need not appear in standard DeviceInfo.props.
    for ((property, label) in coreProperties + relatedProperties) {
        val (rc, data) = read("$label descriptor", 0x1014, property)
        if (property in setOf(0xD200, 0xD237) && rc == 0x2001 && data != null) {
            runCatching { NikonPictureControlSelection.parse(data, property) }.fold(
                onSuccess = {
                    log("$label writable=${it.writable} current=${it.current} " +
                        "confirmedLastCustomSlot=${it.confirmedLastCustomSlot} choices=${it.choices}")
                    items += it.choices.filter { item -> item in 1..65535 }
                    if (it.current in 1..65535) items += it.current
                },
                onFailure = { log("!! $label descriptor parse: ${it.message}; raw retained") },
            )
        }
        val (valueRc, value) = read("$label value", 0x1015, property)
        if (valueRc == 0x2001 && value != null && property in setOf(0xD200, 0xD237)) {
            initialValues[property] = value.copyOf()
            if (value.size == 2) {
                val item = (value[0].toInt() and 255) or ((value[1].toInt() and 255) shl 8)
                if (item in 1..65535) items += item
            }
        }
    }
    // Read the complete fixed custom range, even if only occupied slots are enumerated.
    // These fallback reads never authorize writing a slot absent from the descriptor.
    items += listOf(1, 4)
    items += 201..209
    codes("Picture Control items (requests also show decimal IDs)", items)
    if (0x90CC in info.operations) {
        for (item in items) read("item=$item second-argument=0", 0x90CC, item, 0)
    } else log("GetPicCtrlData not advertised; item reads skipped")

    log("Capability argument semantics unverified; raw argument comparison follows")
    if (0x90CF in info.operations) {
        for (argument in listOf(0) + items) read("capability argument=$argument", 0x90CF, argument)
    } else log("GetPicCtrlCapability not advertised; capability reads skipped")

    if (0x90CC in info.operations && 0x90CC !in unsupportedOperations) {
        log("GetPicCtrlData second-argument 1..3 semantics unverified; no write format inferred")
        for (argument in 1..3) {
            val canaries = listOf(1, 4, 209)
            val results = canaries.map { item ->
                read("item=$item second-argument=$argument", 0x90CC, item, argument).first
            }
            // Busy/access errors cannot establish that a raw argument is unsupported.
            if (results.all { it in setOf(0x2005, 0x2006, 0x201D) }) {
                skipped += items.size - canaries.size
                log("SKIP remaining items for second-argument=$argument: all reference reads rejected it")
            } else {
                for (item in items - canaries.toSet()) {
                    read("item=$item second-argument=$argument", 0x90CC, item, argument)
                }
            }
        }
    }
    for ((property, before) in initialValues) {
        val (rc, after) = read("final selection 0x%04X".format(property), 0x1015, property)
        log("selection 0x%04X unchanged=%s".format(property,
            if (rc == 0x2001 && after != null) before.contentEquals(after).toString() else "unverified"))
    }
    log("probe complete: requests=$requests nonOKResponses=$errors skipped=$skipped " +
        "uniquePayloadBytes=${payloads.uniqueBytes}; no data written, deleted, or activated")
    checkpoint(requests)
}

internal fun parsePictureControlVendorCodes(data: ByteArray, width: Int): Set<Int> {
    require(width == 2 || width == 4)
    require(data.size >= 4) { "Missing vendor property count" }
    val input = ByteBuffer.wrap(data).order(ByteOrder.LITTLE_ENDIAN)
    val count = input.int.toLong() and 0xFFFFFFFFL
    require(count * width == input.remaining().toLong()) { "Invalid vendor property list length" }
    return buildSet { repeat(count.toInt()) { add(if (width == 2) input.short.toInt() and 65535 else input.int) } }
}

/** Complete reconstructable hex; repeated data refers to its first occurrence by SHA-256. */
internal class PictureControlProbePayloads(private val log: (String) -> Unit) {
    private val seen = mutableMapOf<String, String>()
    var uniqueBytes = 0L
        private set

    fun record(id: String, data: ByteArray?) {
        if (data == null) { log("$id data=<none>"); return }
        val hash = hex(MessageDigest.getInstance("SHA-256").digest(data))
        val previous = seen[hash]
        if (previous != null) { log("$id dataRef=$previous sha256=$hash"); return }
        seen[hash] = id
        uniqueBytes += data.size
        log("$id sha256=$hash")
        if (data.isEmpty()) log("$id data=<empty>")
        for (offset in data.indices step 256) {
            log("$id data[%06X]=".format(offset) + hex(data.copyOfRange(offset, minOf(offset + 256, data.size))))
        }
    }

    private fun hex(bytes: ByteArray): String {
        val digits = "0123456789ABCDEF"
        return buildString(bytes.size * 2) {
            for (byte in bytes) {
                val value = byte.toInt() and 255
                append(digits[value shr 4]); append(digits[value and 15])
            }
        }
    }
}
