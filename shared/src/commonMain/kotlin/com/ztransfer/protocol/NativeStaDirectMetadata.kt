package com.ztransfer.protocol

import com.ztransfer.preview.parseNefHeaderMetadata
import com.ztransfer.preview.staDirectCaptureDate

/** Session-owned scalar facade; all filename, MakerNote, Nikon index and RAW parsing is shared. */
class NativeStaDirectMetadata {
    private val dates = mutableMapOf<Int, String>()
    private val names = mutableMapOf<Int, String>()
    private val anchors = mutableMapOf<Int, NikonFileNumberAnchor>()
    private var sessionAnchor: NikonFileNumberAnchor? = null

    fun loadDates(data: ByteArray) { dates.putAll(parseNikonObjectsMetadataCaptureDates(data)) }
    fun loadNames(data: ByteArray) { names.putAll(parseObjectFileNamePropertyList(data)) }
    fun name(handle: Int): String? = names[handle]
    fun captureDate(handle: Int): String? = dates[handle]
    fun loadName(handle: Int, data: ByteArray): String? =
        parsePtpObjectFileName(data)?.first?.also { names[handle] = it }

    fun invalidate(handle: Int) { dates.remove(handle); names.remove(handle); anchors.clear(); sessionAnchor = null }
    fun clear() { dates.clear(); names.clear(); anchors.clear(); sessionAnchor = null }

    /** A card-specific anchor never borrows the other card's numbering. Zero means unknown/aliases. */
    fun indexedInfo(handle: Int, size: Long, storageId: Int): PtpObjectInfo? {
        if (size <= 0) return null
        val extension = staDirectExtensionFromHandle(handle) ?: return null
        val date = dates[handle] ?: return null
        val anchor = if (storageId != 0) anchors[storageId] else sessionAnchor
        val name = names[handle] ?: anchor?.let { deriveNikonMakerFileInfo(it, handle) }
            ?.let { nikonDefaultCameraFileName(it, extension) } ?: return null
        return info(handle, size, name, date)
    }

    fun headerInfo(handle: Int, size: Long, header: ByteArray, exifDate: String?, storageId: Int): PtpObjectInfo? {
        if (size <= 0 || header.isEmpty()) return null
        val detected = staDirectObjectExtension(header)
        val embedded = if (names[handle] == null) findEmbeddedCameraFileNames(header, includePtpStrings = false)
            .firstOrNull { it.value.substringAfterLast('.').equals(detected.removePrefix("."), true) }?.value else null
        val maker = if (detected in setOf(".jpg", ".nef")) nikonMakerFileInfo(header) else null
        if (maker != null) {
            val anchor = NikonFileNumberAnchor(handle and 0x00FFFFFF, maker.directoryNumber, maker.fileNumber)
            sessionAnchor = anchor
            if (storageId != 0) anchors[storageId] = anchor
        }
        val anchor = if (storageId != 0) anchors[storageId] else sessionAnchor
        val derived = maker ?: anchor?.let { deriveNikonMakerFileInfo(it, handle) }
        val original = names[handle] ?: embedded ?: derived?.let { nikonDefaultCameraFileName(it, detected) }
        if (original != null) names[handle] = original
        val extension = if (detected == ".bin" && original != null) "." + original.substringAfterLast('.').lowercase() else detected
        val date = (if (extension == ".nef") parseNefHeaderMetadata(header).captureDate else null)
            ?: staDirectCaptureDate(exifDate) ?: dates[handle]
        val name = original?.takeIf { it.substringAfterLast('.').equals(extension.removePrefix("."), true) }
            ?: buildString {
                append("ZTransfer_")
                date?.filter(Char::isDigit)?.take(14)?.takeIf(String::isNotEmpty)?.let { append(it).append('_') }
                append(handle.toUInt().toString(16).uppercase().padStart(8, '0'))
                append(extension)
            }
        return info(handle, size, name, date)
    }

    // Direct mode has no authoritative ObjectInfo storage/protection flags. Membership comes from
    // analyzeStaDirectStorageLayout, not this scalar object. Never invent "protected" or a slot.
    private fun info(handle: Int, size: Long, name: String, date: String?) =
        PtpObjectInfo(handle, 0, 0, size, name, date, false, false, true)
}
