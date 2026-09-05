package com.ztransfer.ui

import com.ztransfer.protocol.CameraFileInfo
import kotlinx.coroutines.*
import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.resume

/** Opaque, owned PNG bytes. Header bounds do not replace actual image decoding. */
class NativeFhdPreviewImage internal constructor(
    internal val encoded: ByteArray,
    val width: Int,
    val height: Int,
)

internal fun ownedFhdPreviewPng(bytes: ByteArray): NativeFhdPreviewImage? {
    if (!isBoundedSinglePhotoPng(bytes)) return null
    fun dimension(offset: Int): Int = (offset until offset + 4).fold(0) { value, i ->
        (value shl 8) or (bytes[i].toInt() and 255)
    }
    val width = dimension(16)
    val height = dimension(20)
    if (width !in 1..1920 || height !in 1..1920) return null
    return NativeFhdPreviewImage(bytes, width, height)
}

interface NativeFhdPreviewCompletion { fun complete(image: NativeFhdPreviewImage?) }

/** Main/UI-thread calls and completions. This borrows the existing camera, never creates one. */
interface NativePreviewReadPlatform {
    fun beginPreviewReads(sessionId: Long)
    fun readFhdPreview(sessionId: Long, requestId: Long, file: CameraFileInfo, completion: NativeFhdPreviewCompletion)
    fun readLocalBitmap(sessionId: Long, requestId: Long, source: String, completion: NativeLocalPreviewCompletion) {
        completion.complete(null)
    }
    fun readLocalRaw(sessionId: Long, requestId: Long, source: String, completion: NativeLocalPreviewCompletion) {
        completion.complete(null)
    }
    fun cancelPreviewRead(sessionId: Long, requestId: Long)
    fun endPreviewReads(sessionId: Long)
}

/** One overlay's read lifetime, separate from the parent grid and its queue model. */
class NativePreviewReadSession internal constructor(
    private val sessionId: Long,
    platform: NativePreviewReadPlatform,
    isCurrentFile: (CameraFileInfo) -> Boolean,
    private val uiContext: CoroutineContext = Dispatchers.Main.immediate,
    private val timeoutMillis: Long = 30_000L,
    isFrozenLocalSource: (CameraFileInfo, String) -> Boolean = { _, _ -> false },
) {
    private var closed = false
    private var owner: NativePreviewReadPlatform? = platform
    private var currentFile: ((CameraFileInfo) -> Boolean)? = isCurrentFile
    private var localSource: ((CameraFileInfo, String) -> Boolean)? = isFrozenLocalSource
    private var nextRequest = 0L
    private val pending = HashMap<Long, CancellableContinuation<*>>()

    init { platform.beginPreviewReads(sessionId) }

    @Throws(CancellationException::class)
    suspend fun fhd(file: CameraFileInfo): NativeFhdPreviewImage? = read(
        allowed = { currentFile?.invoke(file) == true },
        start = { bridge, request, reply ->
            bridge.readFhdPreview(sessionId, request, file, object : NativeFhdPreviewCompletion {
                override fun complete(image: NativeFhdPreviewImage?) = reply(image)
            })
        },
    )

    /** Uses the opening snapshot; disconnects and newly completed originals cannot hot-swap it. */
    @Throws(CancellationException::class)
    suspend fun localBitmap(file: CameraFileInfo, source: String): NativeLocalPreviewImage? = read(
        allowed = { localSource?.invoke(file, source) == true },
        start = { bridge, request, reply ->
            bridge.readLocalBitmap(sessionId, request, source, object : NativeLocalPreviewCompletion {
                override fun complete(image: NativeLocalPreviewImage?) = reply(image)
            })
        },
    )

    /** Same frozen source and cancellation budget, but never decode the RAW container directly. */
    @Throws(CancellationException::class)
    suspend fun localRaw(file: CameraFileInfo, source: String): NativeLocalPreviewImage? = read(
        allowed = { localSource?.invoke(file, source) == true },
        start = { bridge, request, reply ->
            bridge.readLocalRaw(sessionId, request, source, object : NativeLocalPreviewCompletion {
                override fun complete(image: NativeLocalPreviewImage?) = reply(image)
            })
        },
    )

    private suspend fun <T> read(
        allowed: () -> Boolean,
        start: (NativePreviewReadPlatform, Long, (T?) -> Unit) -> Unit,
    ): T? = withContext(uiContext) {
        val bridge = owner ?: return@withContext null
        if (closed || !allowed() || pending.size >= 32 || nextRequest == Long.MAX_VALUE) return@withContext null
        val request = ++nextRequest
        var completed = false
        try {
            // A read deadline is a miss, not a page cancellation. Parent cancellation still escapes.
            withTimeoutOrNull(timeoutMillis) {
                suspendCancellableCoroutine<T?> { continuation ->
                    pending[request] = continuation
                    start(bridge, request) { image ->
                        if (!closed && pending[request] === continuation && continuation.isActive) {
                            completed = true
                            pending.remove(request)
                            continuation.resume(image.takeIf { allowed() })
                        }
                    }
                }
            }
        } finally {
            // Cancellation may originate off UI; never call a MainActor bridge from that thread.
            withContext(NonCancellable + uiContext) {
                pending.remove(request)
                if (!completed) bridge.cancelPreviewRead(sessionId, request)
            }
        }
    }

    /** Called from the UI owner. Idempotent; does not close the grid, transport or queue. */
    fun close() {
        if (closed) return
        closed = true
        val bridge = owner; owner = null; currentFile = null; localSource = null
        pending.values.toList().forEach { it.cancel() }
        pending.clear()
        bridge?.endPreviewReads(sessionId)
    }
}
