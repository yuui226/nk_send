package com.ztransfer.filter

import com.ztransfer.lut.CubeLut
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutionException
import java.util.concurrent.FutureTask

/** Loaded resources are owned by active renders or this bounded cache, never by queued recipes. */
internal class PhotoCubeResourceCache(
    private val budget: Int = 8 * 1024 * 1024,
    private val maxEntries: Int = 16,
) {
    class Loaded(val table: CubeLut) {
        val mapper = PhotoCubeMapper(table)
        val bytes: Int = mapper.budgetBytes
    }

    private val lock = Any()
    private val entries = LinkedHashMap<String, Loaded>(16, .75f, true)
    private val loading = ConcurrentHashMap<String, FutureTask<Loaded>>()
    private var bytes = 0

    fun acquire(key: String, read: () -> CubeLut): Loaded {
        synchronized(lock) { entries[key] }?.let { return it }
        val job = loading.computeIfAbsent(key) {
            FutureTask {
                synchronized(lock) { entries[key] } ?: remember(key, Loaded(read()))
            }
        }
        try {
            // Exactly one caller runs it. No disk I/O under the cache lock; another LUT's
            // cache hit can proceed while this immutable snapshot is being read.
            job.run()
            return job.get()
        } catch (error: ExecutionException) {
            throw (error.cause ?: error)
        } finally {
            if (job.isDone) loading.remove(key, job)
        }
    }

    fun seed(key: String, table: CubeLut) {
        if (synchronized(lock) { entries.containsKey(key) }) return
        remember(key, Loaded(table))
    }

    private fun remember(key: String, loaded: Loaded): Loaded = synchronized(lock) {
        entries[key]?.let { return it }
        if (loaded.bytes > budget || maxEntries <= 0) return loaded
        while ((bytes + loaded.bytes > budget || entries.size >= maxEntries) && entries.isNotEmpty()) {
            entries.remove(entries.keys.first())?.let { bytes -= it.bytes }
        }
        entries[key] = loaded
        bytes += loaded.bytes
        loaded
    }

    internal val retainedBytes: Int get() = synchronized(lock) { bytes }
}
