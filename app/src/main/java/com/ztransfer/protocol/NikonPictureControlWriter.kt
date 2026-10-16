package com.ztransfer.protocol

import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/** Both registered defaults and user adjustments must survive replacement/rollback. */
internal class NikonPictureControlSlotState(val defaults: NikonPictureControlData, val current: NikonPictureControlData) {
    init {
        require(!defaults.isEmpty && !current.isEmpty && defaults.baseItem == current.baseItem)
    }
    fun bytes(): ByteArray {
        val d = defaults.bytes(); val c = current.bytes()
        return ByteBuffer.allocate(12 + d.size + c.size).order(ByteOrder.LITTLE_ENDIAN)
            .putInt(0x31534350).putInt(d.size).putInt(c.size).put(d).put(c).array()
    }
    companion object {
        fun fromDataset(slot: Int, data: ByteArray): NikonPictureControlSlotState {
            val parsed = NikonPictureControlData.parseResponse(slot, 0x2001, data)
            return NikonPictureControlSlotState(parsed, parsed)
        }
        fun parse(slot: Int, bytes: ByteArray): NikonPictureControlSlotState {
            require(bytes.size >= 12) { "Truncated slot snapshot" }
            val input = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
            require(input.int == 0x31534350) { "Unknown slot snapshot format" }
            val d = input.int; val c = input.int
            require(d in setOf(36, 614) && c in setOf(36, 614) && input.remaining() == d + c)
            fun read(size: Int) = NikonPictureControlData.parseResponse(slot, 0x2001,
                ByteArray(size).also(input::get))
            return NikonPictureControlSlotState(read(d), read(c))
        }
    }
}

internal fun interface PictureControlTransport {
    suspend fun exchange(code: Int, params: IntArray, data: ByteArray?): Pair<Int, ByteArray?>
}

internal enum class PictureControlSlotAvailability { OCCUPIED, EMPTY, UNREADABLE, UNSUPPORTED }
internal data class PictureControlSlotInfo(
    val slot: Int,
    val availability: PictureControlSlotAvailability,
    val name: String? = null,
    val hasOriginal: Boolean = false,
) {
    val number: Int get() = slot - 200
    val readable: Boolean get() = availability == PictureControlSlotAvailability.OCCUPIED ||
        availability == PictureControlSlotAvailability.EMPTY
}
internal data class PictureControlOverview(
    val slots: List<PictureControlSlotInfo>, val selected: Int,
    val canActivate: Boolean, val canEdit: Boolean,
)
internal sealed interface PictureControlChange {
    data class Write(val file: NikonPictureControlFile) : PictureControlChange
    data object Activate : PictureControlChange
    data object Clear : PictureControlChange
    data object Restore : PictureControlChange
}

/** Every adapter binds its mutation target once; system Picture Controls are never writable. */
internal class NikonPictureControlAccess(
    override val cameraIdentity: String,
    override val slot: Int,
    private val movie: Boolean,
    private val operations: Set<Int>,
    private val sessionCheck: () -> Boolean,
    private val transport: PictureControlTransport,
    private val log: ((String) -> Unit)?,
) : PictureControlSlotAccess {
    init { require(slot in NIKON_PICTURE_CONTROL_SLOTS) { "Only C1–C9 are custom slots" } }
    private val mode get() = if (movie) 1 else 0
    private val property get() = if (movie) 0xD237 else 0xD200
    private var selection: NikonPictureControlSelection? = null
    private var writePrepared = false
    private var selectionPrepared = false
    private val writeOperations = setOf(0x1014, 0x1015, 0x1016, 0x90CC, 0x90CD, 0x90CE, 0x90CF)

    override suspend fun checkSession() { check(sessionCheck()) { "Camera session changed" } }

    private suspend fun command(code: Int, params: IntArray, data: ByteArray? = null): ByteArray? {
        checkSession()
        if (data != null) log?.invoke("out op=0x%04X params=%s bytes=%d data=%s".format(code,
            params.joinToString(), data.size, data.joinToString("") { "%02x".format(it) }))
        val (rc, received) = transport.exchange(code, params, data)
        log?.invoke("in op=0x%04X params=%s rc=0x%04X bytes=%d data=%s".format(code, params.joinToString(), rc,
            received?.size ?: 0, received?.joinToString("") { "%02x".format(it) }.orEmpty()))
        check(rc == 0x2001) { "Picture Control op=0x%04X failed: 0x%04X".format(code, rc) }
        return received
    }

    private suspend fun selectionDescriptor(): NikonPictureControlSelection =
        NikonPictureControlSelection.parse(requireNotNull(command(0x1014, intArrayOf(property))), property)

    suspend fun prepareSelection() {
        selectionPrepared = false
        writePrepared = false
        selection = null
        check(setOf(0x1014, 0x1015, 0x1016, 0x90CC).all(operations::contains)) {
            "Camera does not advertise Picture Control activation"
        }
        val descriptor = selectionDescriptor()
        check(descriptor.writable && descriptor.supportsSlot(slot)) { "Camera does not expose writable C${slot - 200}" }
        check(readU16(0x500E) in 1..4) { "Set the camera exposure mode to P, S, A or M" }
        selection = descriptor
        selectionPrepared = true
    }

    suspend fun prepare(dataset: ByteArray? = null) {
        writePrepared = false
        check(writeOperations.all(operations::contains)) { "Camera does not advertise Picture Control editing" }
        prepareSelection()
        if (dataset != null) {
            val parsed = NikonPictureControlData.parseResponse(slot, 0x2001, dataset)
            check(parsed.baseItem in checkNotNull(selection).choices) { "Camera does not support this base Picture Control" }
            val base = readData(parsed.baseItem, 1)
            check(!base.isEmpty && base.baseItem == parsed.baseItem) { "Unexpected base Picture Control layout" }
            validatePictureControlCapabilities(dataset,
                requireNotNull(command(0x90CF, intArrayOf(parsed.baseItem, mode))))
        }
        writePrepared = true
    }

    /** Read all names once per refresh; an unreadable row is never presented as an empty slot. */
    suspend fun overview(backup: PictureControlBackupStore): PictureControlOverview {
        check(setOf(0x1014, 0x1015, 0x90CC).all(operations::contains)) { "Picture Control reading is unavailable" }
        val descriptor = selectionDescriptor()
        val selected = readSelection().toInt()
        val slots = NIKON_PICTURE_CONTROL_SLOTS.map { item ->
            val hasOriginal = runCatching { backup.load(cameraIdentity, item) != null }.getOrDefault(false)
            if (!descriptor.supportsSlot(item)) PictureControlSlotInfo(item, PictureControlSlotAvailability.UNSUPPORTED)
            else try {
                val current = readData(item, 0)
                PictureControlSlotInfo(item,
                    if (current.isEmpty) PictureControlSlotAvailability.EMPTY else PictureControlSlotAvailability.OCCUPIED,
                    current.name.takeUnless { current.isEmpty }, hasOriginal)
            } catch (error: CancellationException) { throw error }
            catch (error: IOException) { throw error } // Broken transport: do not issue eight more doomed reads.
            catch (_: Exception) { PictureControlSlotInfo(item, PictureControlSlotAvailability.UNREADABLE, hasOriginal = hasOriginal) }
        }
        return PictureControlOverview(slots, selected,
            descriptor.writable && 0x1016 in operations,
            descriptor.writable && writeOperations.all(operations::contains))
    }

    private suspend fun readData(item: Int, defaultFlag: Int): NikonPictureControlData =
        NikonPictureControlData.parseResponse(item, 0x2001,
            command(0x90CC, intArrayOf(item, defaultFlag, mode)))

    override suspend fun readSlot(): ByteArray? {
        val current = readData(slot, 0)
        val defaults = readData(slot, 1)
        check(current.isEmpty == defaults.isEmpty) { "Custom slot current/default registration differs" }
        return if (current.isEmpty) null else NikonPictureControlSlotState(defaults, current).bytes()
    }

    override fun matchesSlot(expected: ByteArray?, actual: ByteArray?): Boolean {
        if (expected == null || actual == null) return expected == null && actual == null
        val wanted = NikonPictureControlSlotState.parse(slot, expected)
        val received = NikonPictureControlSlotState.parse(slot, actual)
        // Z30 V1.20 returns all 614 bytes for Current, but only the 36-byte header
        // (CustomCurveFlag=0) for Default after accepting the same 614-byte registration.
        // Allow only that omission: the complete current curve and every scalar in both
        // datasets must still match. A different returned default curve is never ignored.
        if (!wanted.current.bytes().contentEquals(received.current.bytes())) return false
        val wantedDefaults = wanted.defaults.bytes()
        val receivedDefaults = received.defaults.bytes()
        return wantedDefaults.contentEquals(receivedDefaults) ||
            (wantedDefaults.size == 614 && receivedDefaults.size == 36 &&
                wantedDefaults[35] == 1.toByte() && receivedDefaults[35] == 0.toByte() &&
                wantedDefaults.copyOfRange(0, 35).contentEquals(receivedDefaults.copyOfRange(0, 35)))
    }

    override suspend fun writeSlot(data: ByteArray) {
        check(writePrepared) { "Slot write was not prepared" }
        val state = NikonPictureControlSlotState.parse(slot, data)
        // ModifiedFlag=0 registers/replaces the preset, including a different base style.
        command(0x90CD, intArrayOf(slot, 0, mode), state.defaults.bytes())
        if (!state.current.bytes().contentEquals(state.defaults.bytes())) {
            // ModifiedFlag=1 restores adjustments without losing the registered defaults.
            command(0x90CD, intArrayOf(slot, 1, mode), state.current.bytes())
        }
    }

    override suspend fun clearSlot() {
        check(writePrepared) { "Slot deletion was not prepared" }
        command(0x90CE, intArrayOf(slot, mode))
    }

    private suspend fun readU16(prop: Int): Int {
        val bytes = requireNotNull(command(0x1015, intArrayOf(prop)))
        require(bytes.size == 2) { "Unexpected Picture Control property format" }
        return (bytes[0].toInt() and 255) or ((bytes[1].toInt() and 255) shl 8)
    }
    override suspend fun readSelection(): Long = readU16(property).toLong()
    override suspend fun select(value: Long) {
        check(selectionPrepared) { "Picture Control selection was not prepared" }
        require(value in checkNotNull(selection).choices.map(Int::toLong)) { "Invalid Picture Control selection" }
        command(0x1016, intArrayOf(property), byteArrayOf(value.toByte(), (value shr 8).toByte()))
    }
}

/** Keep one camera transaction for preflight, backup, mutation, verification and rollback. */
internal suspend fun NikonCamera.changePictureControl(
    filesDir: File, slot: Int, change: PictureControlChange, movie: Boolean,
    isCurrentCamera: () -> Boolean, log: (String) -> Unit,
) {
    val dataset = (change as? PictureControlChange.Write)?.file?.encodeClassicPictureControl()
    withPictureControlAccess(filesDir, slot, movie, isCurrentCamera, log) { access, backup ->
        val replacement = PictureControlReplacement(backup)
        when (change) {
            is PictureControlChange.Write -> {
                access.prepare(checkNotNull(dataset))
                replacement.apply(access, NikonPictureControlSlotState.fromDataset(slot, dataset).bytes())
            }
            PictureControlChange.Activate -> { access.prepareSelection(); replacement.activate(access) }
            PictureControlChange.Clear -> { access.prepare(); replacement.clear(access) }
            PictureControlChange.Restore -> { access.prepare(); replacement.restoreOriginal(access) }
        }
        log("SUCCESS: C${slot - 200} operation and active selection verified")
    }
}

internal suspend fun NikonCamera.readPictureControlOverview(
    filesDir: File, movie: Boolean, isCurrentCamera: () -> Boolean,
): PictureControlOverview = withPictureControlAccess(filesDir, NIKON_PICTURE_CONTROL_SLOTS.first, movie,
    isCurrentCamera, null, atomic = false) { access, backup -> access.overview(backup) }

private suspend fun <T> NikonCamera.withPictureControlAccess(
    filesDir: File,
    slot: Int,
    movie: Boolean,
    isCurrentCamera: () -> Boolean,
    log: ((String) -> Unit)?,
    atomic: Boolean = true,
    block: suspend (NikonPictureControlAccess, PictureControlBackupStore) -> T,
): T {
    val info = requireNotNull(cachedDeviceInfo) { "Camera information unavailable" }
    check(info.manufacturer.contains("Nikon", ignoreCase = true)) { "Not a Nikon camera" }
    val identity = thumbnailCacheIdentity
    check(identity.substringAfterLast('\u0000') != "unknown-device") { "A stable camera identity is required for slot backups" }
    val backup = PictureControlBackupStore(File(filesDir, "picture_control_backups"))
    val bankIdentity = "$identity\u0000picture-control-${if (movie) "movie" else "photo"}"
    log?.invoke("camera=${info.model} firmware=${info.deviceVersion} transport=$connectionType movie=$movie target=C${slot - 200}")
    suspend fun runAccess(): T = withContext(Dispatchers.IO) {
        val access = NikonPictureControlAccess(bankIdentity, slot, movie, info.operations, isCurrentCamera,
            PictureControlTransport { code, params, data ->
                currentCoroutineContext().ensureActive()
                suspend fun exchange() = withContext(NonCancellable) {
                    val oldTimeout = setCommandReadTimeout(5_000)
                    try {
                        if (data == null) sendCmd(code, *params) else sendCmdWithData(code, data, *params)
                        recvRespWithPayload()
                    } catch (error: IOException) {
                        abortProtocolTransport()
                        throw error
                    } finally { restoreCommandReadTimeout(oldTimeout) }
                }
                // Read-only enumeration yields the camera channel between complete PTP
                // exchanges so monitor frames can proceed. Mutations remain fully atomic.
                if (atomic) exchange() else withCameraTransaction(
                    CameraRequestKind.INTERACTIVE, "PICTURE_CONTROL_READ",
                ) { exchange() }
            }, log)
        block(access, backup)
    }
    return focusMutex.withLock {
        if (atomic) withCameraTransaction(CameraRequestKind.INTERACTIVE, "PICTURE_CONTROL_WRITE") {
            runAccess()
        } else {
            runAccess()
        }
    }
}
