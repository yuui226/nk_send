package com.ztransfer.viewmodel

import java.io.File
import java.util.UUID
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Small immutable results; never retain an input header or a decoded image in [value]. */
internal data class PreparedPhotoMetadata<T>(val value: T?, val state: State, val detail: String? = null) {
    enum class State { COMPLETE, NO_EXIF, PARTIAL, FAILED }
}

/**
 * A single fast parser and a separate bounded camera-read consumer. A slow camera cannot
 * prevent captured headers being parsed/released. Shared requests retain only small results.
 */
internal class PhotoMetadataPreparation<K, T>(
    scope: CoroutineScope,
    dispatcher: CoroutineDispatcher,
    private val directory: File,
    private val parse: (ByteArray) -> PreparedPhotoMetadata<T>,
    private val memoryLimit: Long = 2L * 1024 * 1024,
    private val diskLimit: Long = 16L * 1024 * 1024,
    private val maxRequests: Int = 4096,
    private val maxCachedResults: Int = 256,
    private val merge: (T?, T?) -> T? = { previous, next -> next ?: previous },
) {
    private sealed interface Header {
        class Memory(var bytes: ByteArray?) : Header
        class Disk(val file: File, val size: Int) : Header
    }
    private val lock = Any()
    private var memoryBytes = 0L
    private var diskBytes = 0L
    private var waiters = 0
    private var closed = false
    private val pending = HashMap<K, MutableList<(PreparedPhotoMetadata<T>) -> Unit>>()
    private val cached = LinkedHashMap<K, PreparedPhotoMetadata<T>>(16, .75f, true)
    private val parser = PhotoGenerationQueue(scope, dispatcher, maxRequests)
    private val supplemental = PhotoGenerationQueue(scope, dispatcher, maxRequests)
    private val ids = java.util.concurrent.atomic.AtomicLong()
    private val sessionDirectory = File(directory, UUID.randomUUID().toString())

    init {
        require(memoryLimit >= 0 && diskLimit >= 0 && maxCachedResults > 0)
        // Task recovery is process-local. Previous-process header spools have no remaining
        // owners; clean them on the parser worker, never on the download/main thread.
        parser.submit(ids.incrementAndGet(), execute = {
            directory.listFiles()?.filter { it != sessionDirectory }?.forEach { it.deleteRecursively() }
        }, complete = {})
    }

    /** Only an overflow spool write can suspend admission; parsing/camera work is never awaited. */
    suspend fun prepare(
        key: K,
        header: ByteArray?,
        readMore: suspend (Int) -> ByteArray?,
        complete: (PreparedPhotoMetadata<T>) -> Unit,
    ) {
        var immediate: PreparedPhotoMetadata<T>? = null
        var start = false
        synchronized(lock) {
            val hit = cached[key]
            when {
                closed -> immediate = failure("closed")
                hit != null -> immediate = hit
                waiters >= maxRequests -> immediate = failure("preparation capacity reached")
                else -> {
                    waiters++
                    val listeners = pending[key]
                    if (listeners != null) listeners.add(complete)
                    else {
                        pending[key] = mutableListOf(complete)
                        start = true
                    }
                }
            }
        }
        immediate?.let { result -> notifyPhotoCompletion { complete(result) }; return }
        if (!start) return
        if (header == null) {
            supplement(key, null, 256 * 1024, readMore)
            return
        }
        val stored = try { retain(header) } catch (error: Exception) {
            finish(key, failure("header spool: ${error.javaClass.simpleName}"))
            throwIfCancelled(error)
            return
        }
        if (stored == null) {
            finish(key, failure("header budget exhausted"))
            return
        }
        var result: PreparedPhotoMetadata<T>? = null
        val admission = parser.submit(ids.incrementAndGet(), execute = {
            val bytes = when (stored) {
                is Header.Memory -> checkNotNull(stored.bytes)
                is Header.Disk -> stored.file.readBytes()
            }
            result = parse(bytes)
        }, complete = { cause ->
            release(stored)
            val parsed = result ?: failure(cause?.javaClass?.simpleName ?: "parse failed")
            if (parsed.state == PreparedPhotoMetadata.State.PARTIAL && cause == null) {
                supplement(key, parsed, 1024 * 1024, readMore)
            } else finish(key, parsed)
        })
        if (admission != PhotoGenerationQueue.Admission.ACCEPTED) {
            release(stored)
            finish(key, failure("parser $admission"))
        }
    }

    private fun supplement(
        key: K,
        initial: PreparedPhotoMetadata<T>?,
        firstSize: Int,
        readMore: suspend (Int) -> ByteArray?,
    ) {
        var result = initial
        val admission = supplemental.submit(ids.incrementAndGet(), execute = {
            var size = firstSize
            while (true) {
                // Keep only the parsed snapshot across the next suspension, not the previous
                // response array while a larger response is being allocated by the protocol.
                val parsed = readMore(size)?.let(parse)
                if (parsed == null) {
                    result = PreparedPhotoMetadata(result?.value, PreparedPhotoMetadata.State.FAILED, "header unavailable")
                    break
                }
                // A failed larger read must never replace reliable fields with an empty result.
                result = parsed.copy(value = merge(result?.value, parsed.value))
                if (parsed.state != PreparedPhotoMetadata.State.PARTIAL || size >= 2 * 1024 * 1024) break
                size = if (size < 1024 * 1024) 1024 * 1024 else 2 * 1024 * 1024
            }
        }, complete = { cause ->
            finish(key, if (cause == null) result ?: failure("no result")
                else PreparedPhotoMetadata(result?.value, PreparedPhotoMetadata.State.FAILED, cause.javaClass.simpleName))
        })
        if (admission != PhotoGenerationQueue.Admission.ACCEPTED) {
            finish(key, initial ?: failure("supplement $admission"))
        }
    }

    private suspend fun retain(bytes: ByteArray): Header? {
        val useMemory = synchronized(lock) {
            if (bytes.size <= memoryLimit - memoryBytes) { memoryBytes += bytes.size; true }
            else false
        }
        if (useMemory) return Header.Memory(bytes)
        val reserved = synchronized(lock) {
            if (bytes.size <= diskLimit - diskBytes) { diskBytes += bytes.size; true }
            else false
        }
        if (!reserved) return null
        val file = File(sessionDirectory, "${UUID.randomUUID()}.header")
        try {
            withContext(Dispatchers.IO) {
                check(sessionDirectory.isDirectory || sessionDirectory.mkdirs()) { "Cannot create header spool" }
                file.outputStream().use { it.write(bytes) }
            }
            return Header.Disk(file, bytes.size)
        } catch (error: Throwable) {
            file.delete()
            synchronized(lock) { diskBytes -= bytes.size }
            throw error
        }
    }

    private fun release(header: Header) {
        when (header) {
            is Header.Memory -> synchronized(lock) {
                memoryBytes -= checkNotNull(header.bytes).size
                header.bytes = null
            }
            is Header.Disk -> {
                header.file.delete()
                val drained = synchronized(lock) { diskBytes -= header.size; closed && diskBytes == 0L }
                if (drained) sessionDirectory.delete()
            }
        }
    }

    private fun failure(detail: String) = PreparedPhotoMetadata<T>(null, PreparedPhotoMetadata.State.FAILED, detail)

    private fun finish(key: K, result: PreparedPhotoMetadata<T>) {
        val listeners = synchronized(lock) {
            val removed = pending.remove(key) ?: return
            waiters -= removed.size
            if (!closed && result.state != PreparedPhotoMetadata.State.FAILED) {
                cached[key] = result
                while (cached.size > maxCachedResults) cached.remove(cached.keys.first())
            }
            removed
        }
        listeners.forEach { listener -> notifyPhotoCompletion { listener(result) } }
    }

    fun close() {
        synchronized(lock) { closed = true; cached.clear() }
        parser.close()
        supplemental.close()
        val keys = synchronized(lock) { pending.keys.toList() }
        keys.forEach { finish(it, failure("closed")) }
        sessionDirectory.delete() // Only removes an empty directory; active readers retain files.
    }

    private fun throwIfCancelled(error: Exception) {
        if (error is kotlinx.coroutines.CancellationException) throw error
    }
}
