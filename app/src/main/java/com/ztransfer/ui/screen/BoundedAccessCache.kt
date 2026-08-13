package com.ztransfer.ui.screen

/**
 * Small access-ordered cache whose evictions have an explicit lifecycle callback.
 *
 * Synchronization keeps disposal safe if a composition is torn down while background preview
 * work is finishing. Values are never speculatively created: only a requested key enters cache.
 */
internal class BoundedAccessCache<K, V>(
    maxEntries: Int,
    private val createValue: (K) -> V,
    private val closeValue: (V) -> Unit,
) : AutoCloseable {
    private val capacity = maxEntries.also { require(it > 0) }
    private val entries = LinkedHashMap<K, V>(capacity, 0.75f, true)
    private var closed = false

    @Synchronized
    fun getOrCreate(key: K): V {
        check(!closed) { "Cache is closed" }
        entries[key]?.let { return it }
        val created = createValue(key)
        entries[key] = created
        if (entries.size > capacity) {
            val iterator = entries.entries.iterator()
            val eldest = iterator.next()
            iterator.remove()
            closeValue(eldest.value)
        }
        return created
    }

    @Synchronized
    override fun close() {
        if (closed) return
        closed = true
        val values = entries.values.toList()
        entries.clear()
        values.forEach(closeValue)
    }
}
