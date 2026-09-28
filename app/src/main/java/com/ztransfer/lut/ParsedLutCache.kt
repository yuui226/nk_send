package com.ztransfer.lut

/** Process-wide budget, shared by photo and monitor readers; selections remain independent. */
internal class ParsedLutCache(private val budget: Int = 8 * 1024 * 1024, private val maxEntries: Int = 16) {
    private data class Entry(val size: Long, val modified: Long, val table: CubeLut)
    private val entries = LinkedHashMap<String, Entry>(8, .75f, true)
    private var bytes = 0

    @Synchronized fun get(uri: String, size: Long?, modified: Long?): CubeLut? {
        val entry = entries[uri] ?: return null
        if (size == null || modified == null || size != entry.size || modified != entry.modified) {
            remove(uri)
            return null
        }
        return entry.table
    }

    @Synchronized fun remove(uri: String) {
        entries.remove(uri)?.let { bytes -= it.table.rgb.size * 4 }
    }

    @Synchronized fun put(uri: String, size: Long?, modified: Long?, table: CubeLut) {
        remove(uri)
        if (size == null || modified == null || size <= 0 || modified <= 0) return
        val weight = table.rgb.size * 4
        if (weight > budget || maxEntries <= 0) return
        while ((bytes + weight > budget || entries.size >= maxEntries) && entries.isNotEmpty()) remove(entries.keys.first())
        entries[uri] = Entry(size, modified, table)
        bytes += weight
    }
}
