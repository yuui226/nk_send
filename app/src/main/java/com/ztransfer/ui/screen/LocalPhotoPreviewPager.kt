package com.ztransfer.ui.screen

import android.graphics.Bitmap
import android.net.Uri
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.ztransfer.R
import com.ztransfer.filter.PhotoFilterSelection
import com.ztransfer.frame.PhotoFrameExporter
import com.ztransfer.frame.PhotoFrameMetadata
import com.ztransfer.ui.theme.AppTheme
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

private data class LocalPhotoPreview(val bitmap: Bitmap, val metadata: PhotoFrameMetadata)

@Composable
internal fun LocalPhotoPreviewPager(
    photos: List<Uri>,
    effects: LocalPhotoBatchEffects,
    prefetchFilters: List<PhotoFilterSelection>,
    generating: Boolean,
    onChoose: () -> Unit,
    onPageChanged: (Int) -> Unit = {},
) {
    val colors = AppTheme.colors
    if (photos.isEmpty()) {
        Surface(
            onClick = onChoose,
            enabled = !generating,
            shape = RoundedCornerShape(12.dp),
            color = colors.onBackground.copy(alpha = 0.035f),
            border = BorderStroke(1.dp, colors.glassPanelBorder),
            modifier = Modifier.fillMaxWidth().aspectRatio(4f / 3f),
        ) {
            Column(
                verticalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterVertically),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(stringResource(R.string.local_photo_choose_short), color = colors.accentBlue,
                    style = MaterialTheme.typography.labelLarge)
                Text(stringResource(R.string.local_photo_multi_select), color = colors.onSurfaceVariant,
                    style = MaterialTheme.typography.bodySmall)
            }
        }
        return
    }

    // A new selection starts on page one; no map of decoded images grows with the selection.
    key(photos) {
        val pager = rememberPagerState { photos.size }
        Column {
            HorizontalPager(
                state = pager,
                key = { photos[it].toString() },
                beyondViewportPageCount = 0,
                pageSpacing = 12.dp,
                modifier = Modifier.fillMaxWidth().aspectRatio(4f / 3f),
            ) { index ->
                LocalPhotoPreviewPage(
                    uri = photos[index],
                    effects = effects,
                    prefetchFilters = if (index == pager.settledPage && !generating) prefetchFilters else emptyList(),
                )
            }
            LaunchedEffect(pager.currentPage) { onPageChanged(pager.currentPage) }
        }
    }
}

@Composable
private fun LocalPhotoPreviewPage(
    uri: Uri,
    effects: LocalPhotoBatchEffects,
    prefetchFilters: List<PhotoFilterSelection>,
) {
    val context = LocalContext.current
    val preview by produceState<Result<LocalPhotoPreview>?>(null, uri) {
        value = try {
            Result.success(withContext(Dispatchers.IO) {
                val bitmap = PhotoFrameExporter.decodePreview(context.contentResolver, uri, maxEdge = 1_280)
                    ?: error("Cannot decode selected photo")
                LocalPhotoPreview(bitmap, PhotoFrameExporter.readPreviewMetadata(context.contentResolver, uri))
            })
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            Result.failure(error)
        } catch (error: OutOfMemoryError) {
            Result.failure(error)
        }
    }
    val loaded = preview?.getOrNull()
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        when {
            loaded != null -> PhotoEffectsRenderedPreview(
                source = loaded.bitmap,
                resetOnSourceChange = true,
                metadata = loaded.metadata,
                sourceRotationQuarterTurns = 0,
                requestedRotationQuarterTurns = 0,
                // A stable viewport prevents vertical jumps while paging portrait/landscape photos.
                requestedPortrait = false,
                onRotate = null,
                borderEnabled = effects.borderEnabled,
                preset = effects.preset,
                metadataSettings = effects.metadataSettings,
                previewPlaceholders = true,
                watermark = effects.watermark,
                filter = effects.filter,
                prefetchFilters = prefetchFilters,
                onOpen = null,
            )
            preview == null -> CircularProgressIndicator(Modifier.size(24.dp), strokeWidth = 2.dp)
            else -> Text(stringResource(R.string.local_photo_preview_failed),
                color = AppTheme.colors.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
        }
    }
}
