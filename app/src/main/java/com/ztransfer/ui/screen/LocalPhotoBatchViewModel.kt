package com.ztransfer.ui.screen

import android.app.Application
import android.net.Uri
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.ztransfer.effects.PhotoEffectsBatchProgress
import com.ztransfer.effects.generatePhotoEffectsBatch
import com.ztransfer.filter.PhotoFilterSelection
import com.ztransfer.frame.PhotoFrameExporter
import com.ztransfer.frame.PhotoFrameMetadataSettings
import com.ztransfer.frame.PhotoFramePreset
import com.ztransfer.frame.PhotoFrameWatermark
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import com.ztransfer.frame.LocalPhotoExportException
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

internal data class LocalPhotoBatchEffects(
    val preset: PhotoFramePreset,
    val watermark: PhotoFrameWatermark,
    val borderEnabled: Boolean,
    val metadataSettings: PhotoFrameMetadataSettings,
    val filter: PhotoFilterSelection?,
)

internal enum class LocalPhotoBatchPhase { READY, GENERATING, COMPLETE, PARTIAL, FAILED }

internal data class LocalPhotoFailure(val number: Int, val stage: String, val kind: String, val detail: String)

internal data class LocalPhotoBatchState(
    val photos: List<Uri> = emptyList(),
    val failures: List<LocalPhotoFailure> = emptyList(),
    val phase: LocalPhotoBatchPhase = LocalPhotoBatchPhase.READY,
    val progress: PhotoEffectsBatchProgress = PhotoEffectsBatchProgress(0),
) {
    val generating: Boolean get() = phase == LocalPhotoBatchPhase.GENERATING
}

/** Owns the batch across recompositions/configuration changes. Keeps only URI references. */
internal class LocalPhotoBatchViewModel(application: Application) : AndroidViewModel(application) {
    private val mutableState = MutableStateFlow(LocalPhotoBatchState())
    val state = mutableState.asStateFlow()

    fun select(photos: List<Uri>) {
        if (mutableState.value.generating || photos.isEmpty()) return
        mutableState.value = LocalPhotoBatchState(photos = photos.distinct())
    }

    fun generate(effects: LocalPhotoBatchEffects) {
        val selected = mutableState.value
        if (selected.photos.isEmpty() || selected.phase != LocalPhotoBatchPhase.READY) return
        mutableState.value = selected.copy(
            phase = LocalPhotoBatchPhase.GENERATING,
            failures = emptyList(),
            progress = PhotoEffectsBatchProgress(selected.photos.size),
        )
        viewModelScope.launch {
            val app = getApplication<Application>()
            try {
                val result = generatePhotoEffectsBatch(
                    photos = selected.photos.withIndex().toList(),
                    onProgress = { progress -> mutableState.update { it.copy(progress = progress) } },
                ) { (index, uri) ->
                    withContext(Dispatchers.IO) {
                        var stage = "prepare"
                        try {
                            // Prepare and release sources per worker, not for the entire selection.
                            val source = PhotoFrameExporter.prepareMediaStoreSource(app, app.contentResolver, uri)
                                .getOrThrow()
                            stage = "render"
                            PhotoFrameExporter.exportBesideSource(
                                context = app,
                                resolver = app.contentResolver,
                                source = source,
                                preset = effects.preset,
                                watermark = effects.watermark,
                                borderEnabled = effects.borderEnabled,
                                metadataSettings = effects.metadataSettings,
                                filter = effects.filter,
                            ).getOrThrow()
                            true
                        } catch (cancelled: CancellationException) {
                            throw cancelled
                        } catch (error: Throwable) {
                            if (error !is Exception && error !is OutOfMemoryError) throw error
                            val failure = error as? LocalPhotoExportException
                            val cause = failure?.cause ?: error
                            val chain = generateSequence(cause) { it.cause }.take(8).toList()
                            val kind = when {
                                chain.any { it is OutOfMemoryError } -> "memory"
                                chain.any { it is SecurityException } -> "permission"
                                chain.any { it.message?.contains("ENOSPC", ignoreCase = true) == true } -> "space"
                                chain.any { it is java.io.FileNotFoundException } -> "missing"
                                else -> "unknown"
                            }
                            val detail = chain.takeLast(2).joinToString(" / ") {
                                it.javaClass.simpleName + ": " + it.message.orEmpty().take(200)
                            }
                            android.util.Log.e("LocalPhotoBatch", "Photo ${index + 1} failed at ${failure?.stage ?: stage}", error)
                            mutableState.update { current ->
                                current.copy(failures = (current.failures + LocalPhotoFailure(
                                    index + 1, failure?.stage ?: stage, kind, detail,
                                )).take(5))
                            }
                            false
                        }
                    }
                }
                val finished = mutableState.value.copy(
                    phase = when {
                        result.saved == result.total -> LocalPhotoBatchPhase.COMPLETE
                        result.saved == 0 -> LocalPhotoBatchPhase.FAILED
                        else -> LocalPhotoBatchPhase.PARTIAL
                    },
                    progress = result,
                )
                mutableState.value = finished
                delay(2_400)
                if (mutableState.value === finished) {
                    mutableState.value = finished.copy(phase = LocalPhotoBatchPhase.READY)
                }
            } catch (cancelled: CancellationException) {
                // Only lifecycle disposal cancels a batch; the screen offers no stop action.
                mutableState.value = mutableState.value.copy(phase = LocalPhotoBatchPhase.READY)
                throw cancelled
            }
        }
    }
}
