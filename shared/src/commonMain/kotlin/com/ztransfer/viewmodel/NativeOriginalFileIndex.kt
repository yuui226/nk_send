package com.ztransfer.viewmodel

import com.ztransfer.protocol.CameraFileInfo

internal data class NativeOriginalIndexEntry(val name: String, val size: Long, val folder: String?, val locator: String)

/** Atomic platform publication. No filesystem or URL interpretation occurs in shared code. */
class NativeOriginalIndexUpdate(val revision: Long, val baseRevision: Long, val fullSnapshot: Boolean) {
    private val entries = ArrayList<NativeOriginalIndexEntry>()
    private var valid = true
    fun add(name: String, size: Long, folder: String?, locator: String): Boolean {
        if (name.isEmpty() || size < 0 || locator.isEmpty() ||
            name.any { it == '/' || it == '\\' || it == '\u0000' } ||
            (folder != null && !isDatedTransferFolderName(folder))) {
            valid = false
            return false
        }
        entries += NativeOriginalIndexEntry(name, size, folder, locator)
        return true
    }
    internal fun validatedEntries(): List<NativeOriginalIndexEntry>? = if (valid) entries.toList() else null
}

/** Single UI owner. Same compiled lookup/copy-suffix/size rules used by Android directory indexes. */
internal class NativeOriginalFileIndex {
    private var buckets = HashMap<String, ExistingFileNameIndexCore<String>>()
    var revision: Long = -1L
        private set
    val hasSnapshot: Boolean get() = revision >= 0

    fun apply(update: NativeOriginalIndexUpdate): Boolean {
        if (update.revision < 0 || update.revision < revision) return false
        if (hasSnapshot && update.fullSnapshot && update.revision == revision) return false
        if (!update.fullSnapshot && (!hasSnapshot || update.baseRevision != revision || update.revision < update.baseRevision)) return false
        val entries = update.validatedEntries() ?: return false
        if (!update.fullSnapshot && update.revision == revision && entries.isNotEmpty()) return false
        // All validation precedes mutation; failed updates never erase or partially extend the index.
        val next = if (update.fullSnapshot) HashMap() else buckets
        entries.forEach { entry ->
            next.getOrPut(transferDestinationLookupKey(entry.folder)) { ExistingFileNameIndexCore() }
                .add(entry.name, entry.size, entry.locator)
        }
        buckets = next
        revision = update.revision
        return true
    }

    fun contains(file: CameraFileInfo, folder: String?): Boolean = localLocator(file, folder) != null
    fun localLocator(file: CameraFileInfo, folder: String?): String? =
        buckets[transferDestinationLookupKey(folder)]?.find(file.fileName, file.size)?.value
}

/** Expose existing directory classification to Swift; calendar validity deliberately is not added. */
object NativeOriginalIndexPolicy {
    fun isDateFolder(name: String): Boolean = isDatedTransferFolderName(name)
    fun isPartName(name: String): Boolean = name.startsWith(TRANSFER_PART_PREFIX)
}
