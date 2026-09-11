package com.ztransfer.effects

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.async
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Progress counts settled photos, including failures. Selection size never changes. */
data class PhotoEffectsBatchProgress(
    val total: Int,
    val completed: Int = 0,
    val saved: Int = 0,
) {
    val failed: Int get() = completed - saved
}

/** Exactly two workers at most; neither bitmaps nor one coroutine per selected photo are queued. */
suspend fun <T> generatePhotoEffectsBatch(
    photos: List<T>,
    onProgress: (PhotoEffectsBatchProgress) -> Unit,
    generate: suspend (T) -> Boolean,
): PhotoEffectsBatchProgress = coroutineScope {
    val snapshot = photos.toList()
    val lock = Mutex()
    var next = 0
    var progress = PhotoEffectsBatchProgress(total = snapshot.size)
    onProgress(progress)
    val workers = List(minOf(2, snapshot.size)) {
        async {
            while (true) {
                val index = lock.withLock {
                    if (next < snapshot.size) next++ else null
                } ?: break
                val saved = try {
                    generate(snapshot[index])
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (_: Exception) {
                    false
                }
                lock.withLock {
                    progress = progress.copy(
                        completed = progress.completed + 1,
                        saved = progress.saved + if (saved) 1 else 0,
                    )
                    onProgress(progress)
                }
            }
        }
    }
    workers.forEach { it.await() }
    progress
}
