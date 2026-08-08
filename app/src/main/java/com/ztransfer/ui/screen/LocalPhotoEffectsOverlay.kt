package com.ztransfer.ui.screen

import android.app.Activity
import android.content.Intent
import android.graphics.Bitmap
import android.provider.MediaStore
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.PhotoLibrary
import androidx.compose.material.icons.filled.Save
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.ztransfer.R
import com.ztransfer.filter.PhotoFilterSelection
import com.ztransfer.frame.PhotoFrameExporter
import com.ztransfer.frame.PhotoFrameMediaStoreSource
import com.ztransfer.frame.PhotoFrameMetadata
import com.ztransfer.frame.PhotoFrameWatermark
import com.ztransfer.frame.PhotoFrameWatermarkContent
import com.ztransfer.frame.PhotoFrameWatermarkPosition
import com.ztransfer.frame.isPhotoPlacement
import com.ztransfer.license.LicenseManager
import com.ztransfer.ui.theme.AppTheme
import com.ztransfer.viewmodel.TransferViewModel
import com.ztransfer.viewmodel.freeEditionPhotoFrameWatermark
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private data class LocalPhotoSelection(
    val destination: PhotoFrameMediaStoreSource?,
    val preview: Bitmap,
    val metadata: PhotoFrameMetadata,
)

/**
 * Editor for a phone photo. Its controls persist independently from the transfer pipeline, while
 * the selected source and decoded preview live only for the current visit.
 */
@Composable
fun LocalPhotoEffectsPage(
    viewModel: TransferViewModel,
    onNavigateUp: () -> Unit,
) {
    val state by viewModel.state.collectAsState()
    val isPro by LicenseManager.isPro.collectAsState()
    val colors = AppTheme.colors
    val context = LocalContext.current
    val focusManager = LocalFocusManager.current
    val keyboardController = LocalSoftwareKeyboardController.current
    val scope = rememberCoroutineScope()

    val settingsPreferences = remember(context) { LocalPhotoEffectsPreferences(context) }
    val availableFilterIds = state.photoFilters.map { it.id }
    val initialSettings = remember(settingsPreferences, availableFilterIds) {
        settingsPreferences.restore(availableFilterIds)
    }

    var selection by remember { mutableStateOf<LocalPhotoSelection?>(null) }
    var sourceLoading by remember { mutableStateOf(false) }
    var saving by remember { mutableStateOf(false) }
    var watermarkImageImporting by remember { mutableStateOf(false) }

    var decorationEnabled by remember { mutableStateOf(initialSettings.decorationEnabled) }
    var borderEnabled by remember { mutableStateOf(initialSettings.borderEnabled) }
    var preset by remember { mutableStateOf(initialSettings.preset) }
    var watermarkDraft by remember { mutableStateOf(initialSettings.watermark) }
    var filterId by remember { mutableStateOf(initialSettings.filterId) }
    var filterEnabled by remember { mutableStateOf(initialSettings.filterEnabled) }
    var filterIntensity by remember {
        mutableIntStateOf(initialSettings.filterIntensityPercent)
    }

    val currentSettings = LocalPhotoEffectsSettings(
        decorationEnabled = decorationEnabled,
        borderEnabled = borderEnabled,
        preset = preset,
        watermark = watermarkDraft,
        filterId = filterId,
        filterEnabled = filterEnabled,
        filterIntensityPercent = filterIntensity,
    )
    val latestSettings by rememberUpdatedState(currentSettings)
    LaunchedEffect(currentSettings) {
        settingsPreferences.save(currentSettings)
    }
    DisposableEffect(settingsPreferences) {
        onDispose { settingsPreferences.save(latestSettings) }
    }

    var hintText by remember { mutableStateOf("") }
    var hintVisible by remember { mutableStateOf(false) }
    var hintNonce by remember { mutableIntStateOf(0) }
    fun showHint(text: String) {
        hintText = text
        hintVisible = true
        hintNonce++
    }
    LaunchedEffect(hintNonce) {
        if (hintVisible) {
            delay(2_000)
            hintVisible = false
        }
    }

    val selectFailedText = stringResource(R.string.local_photo_select_failed)
    val saveFailedText = stringResource(R.string.local_photo_save_failed)
    val watermarkProOnlyText = stringResource(R.string.photo_frame_watermark_pro_only)
    val watermarkImageImportFailedText = stringResource(R.string.photo_frame_image_import_failed)
    val savedFormat = stringResource(R.string.local_photo_saved)

    val photoPicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.StartActivityForResult(),
    ) { activityResult ->
        val uri = activityResult.data?.data
            ?.takeIf { activityResult.resultCode == Activity.RESULT_OK }
            ?: return@rememberLauncherForActivityResult
        sourceLoading = true
        scope.launch {
            val selectionResult = withContext(Dispatchers.IO) {
                runCatching {
                    val decoded = PhotoFrameExporter.decodePreview(
                        resolver = context.contentResolver,
                        sourceUri = uri,
                    ) ?: error("Cannot decode selected photo")
                    val metadata = PhotoFrameExporter.readPreviewMetadata(
                        resolver = context.contentResolver,
                        sourceUri = uri,
                    )
                    val destination = PhotoFrameExporter.prepareMediaStoreSource(
                        context = context,
                        resolver = context.contentResolver,
                        sourceUri = uri,
                    ).getOrNull()
                    LocalPhotoSelection(
                        destination = destination,
                        preview = decoded,
                        metadata = metadata,
                    )
                }
            }
            sourceLoading = false
            selectionResult.fold(
                onSuccess = { selected ->
                    selection = selected
                },
                onFailure = { showHint(selectFailedText) },
            )
        }
    }
    val watermarkImagePicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.PickVisualMedia(),
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        watermarkImageImporting = true
        viewModel.importPhotoFrameWatermarkImage(uri) { result ->
            watermarkImageImporting = false
            result.fold(
                onSuccess = { imageHash ->
                    watermarkDraft = watermarkDraft.copy(
                        content = PhotoFrameWatermarkContent.IMAGE,
                        imageHash = imageHash,
                        position = watermarkDraft.position.takeIf { it.isPhotoPlacement() }
                            ?: PhotoFrameWatermarkPosition.PHOTO_BOTTOM_RIGHT,
                    )
                    decorationEnabled = borderEnabled || watermarkDraft.enabled
                },
                onFailure = { showHint(watermarkImageImportFailedText) },
            )
        }
    }

    val selectedFilter = state.photoFilters
        .firstOrNull { it.id == filterId }
        ?.takeIf { filterEnabled }
        ?.let { PhotoFilterSelection(it, filterIntensity) }
    val editorWatermark = when {
        !decorationEnabled -> PhotoFrameWatermark(enabled = false)
        isPro -> watermarkDraft
        else -> freeEditionPhotoFrameWatermark()
    }
    val requestedRenderWatermark = if (
        editorWatermark.content == PhotoFrameWatermarkContent.TEXT
    ) {
        editorWatermark.copy(text = editorWatermark.displayText)
    } else {
        editorWatermark
    }
    var renderWatermark by remember { mutableStateOf(requestedRenderWatermark) }
    LaunchedEffect(requestedRenderWatermark) {
        val previous = renderWatermark
        val changesTextOnly = previous.text != requestedRenderWatermark.text &&
            previous.copy(text = requestedRenderWatermark.text) == requestedRenderWatermark
        if (changesTextOnly) delay(140)
        renderWatermark = requestedRenderWatermark
    }
    val hasEffect = decorationEnabled || selectedFilter != null

    Box(
        modifier = Modifier
            .fillMaxSize()
            .statusBarsPadding()
            .navigationBarsPadding(),
    ) {
        Column(
            modifier = Modifier
                .widthIn(max = 680.dp)
                .fillMaxSize()
                .align(Alignment.TopCenter)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp, vertical = 16.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                GlassButton(
                    onClick = onNavigateUp,
                    modifier = Modifier.size(38.dp),
                    contentPadding = PaddingValues(0.dp),
                ) {
                    Icon(
                        Icons.Default.KeyboardArrowUp,
                        contentDescription = stringResource(R.string.cd_back),
                        tint = colors.onBackground,
                        modifier = Modifier.size(23.dp),
                    )
                }
                Spacer(Modifier.width(10.dp))
                Text(
                    text = stringResource(R.string.local_photo_effects_entry),
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                    color = colors.onBackground,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                Spacer(Modifier.width(8.dp))
                GlassButton(
                    onClick = {
                        photoPicker.launch(
                            Intent(Intent.ACTION_PICK).apply {
                                setDataAndType(
                                    MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                                    "image/*",
                                )
                                putExtra(Intent.EXTRA_LOCAL_ONLY, true)
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            }
                        )
                    },
                    enabled = !sourceLoading && !saving,
                    contentPadding = PaddingValues(horizontal = 11.dp, vertical = 7.dp),
                    modifier = Modifier.height(38.dp),
                ) {
                    if (sourceLoading) {
                        CircularProgressIndicator(
                            color = colors.accentBlue,
                            strokeWidth = 2.dp,
                            modifier = Modifier.size(19.dp),
                        )
                    } else {
                        Icon(
                            Icons.Default.PhotoLibrary,
                            contentDescription = null,
                            tint = colors.accentBlue,
                            modifier = Modifier.size(19.dp),
                        )
                    }
                    Text(
                        text = stringResource(
                            if (selection == null) R.string.local_photo_choose_short
                            else R.string.local_photo_replace
                        ),
                        style = MaterialTheme.typography.labelLarge,
                        color = colors.onBackground,
                    )
                }
            }

            Spacer(Modifier.height(14.dp))
            val previewBitmap = selection?.preview
            if (previewBitmap == null) {
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier
                        .fillMaxWidth()
                        .aspectRatio(4f / 3f)
                        .background(colors.onBackground.copy(alpha = 0.035f), RoundedCornerShape(12.dp))
                        .border(1.dp, colors.glassPanelBorder, RoundedCornerShape(12.dp)),
                ) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Icon(
                            Icons.Default.Image,
                            contentDescription = null,
                            tint = colors.onSurfaceVariant.copy(alpha = 0.62f),
                            modifier = Modifier.size(32.dp),
                        )
                        Spacer(Modifier.height(8.dp))
                        Text(
                            text = stringResource(R.string.local_photo_preview_prompt),
                            style = MaterialTheme.typography.bodySmall,
                            color = colors.onSurfaceVariant,
                        )
                    }
                }
            } else {
                PhotoEffectsRenderedPreview(
                    source = previewBitmap,
                    hideSourceWhileRendering = true,
                    metadata = selection?.metadata ?: PhotoFrameMetadata(
                        make = null,
                        model = null,
                        aperture = null,
                        shutter = null,
                        iso = null,
                        focalLength = null,
                    ),
                    sourceRotationQuarterTurns = 0,
                    requestedRotationQuarterTurns = 0,
                    requestedPortrait = previewBitmap.height > previewBitmap.width,
                    onRotate = null,
                    borderEnabled = decorationEnabled && borderEnabled,
                    preset = preset,
                    watermark = renderWatermark,
                    filter = selectedFilter,
                    onOpen = null,
                )
            }

            Spacer(Modifier.height(10.dp))
            PhotoFilterEditor(
                filters = state.photoFilters,
                selectedId = filterId,
                enabled = filterEnabled,
                intensityPercent = filterIntensity,
                onDisabled = { filterEnabled = false },
                onSelected = {
                    filterId = it
                    filterEnabled = true
                },
                onIntensityChanged = { filterIntensity = it },
                hapticsEnabled = state.hapticsEnabled,
            )
            Spacer(Modifier.height(10.dp))
            PhotoFrameWatermarkEditor(
                borderEnabled = decorationEnabled && borderEnabled,
                preset = preset,
                watermark = editorWatermark,
                isPro = isPro,
                hapticsEnabled = state.hapticsEnabled,
                onBorderEnabledChanged = { enabled ->
                    borderEnabled = enabled
                    decorationEnabled = enabled || (isPro && watermarkDraft.enabled)
                    if (!enabled && !watermarkDraft.position.isPhotoPlacement()) {
                        watermarkDraft = watermarkDraft.copy(
                            position = PhotoFrameWatermarkPosition.PHOTO_BOTTOM_RIGHT,
                        )
                    }
                },
                onPresetChanged = { preset = it },
                onWatermarkChanged = { updated ->
                    if (isPro) {
                        watermarkDraft = updated
                        decorationEnabled = borderEnabled || updated.enabled
                    }
                },
                onWatermarkTextCommitted = { text ->
                    if (isPro) watermarkDraft = watermarkDraft.copy(text = text)
                },
                imageImporting = watermarkImageImporting,
                onProRequired = { showHint(watermarkProOnlyText) },
                onImageRequested = {
                    if (isPro && !watermarkImageImporting) {
                        watermarkImagePicker.launch(
                            PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)
                        )
                    }
                },
            )

            Spacer(Modifier.height(12.dp))
            GlassButton(
                onClick = {
                    val selectedSource = selection?.destination ?: run {
                        showHint(selectFailedText)
                        return@GlassButton
                    }
                    focusManager.clearFocus()
                    keyboardController?.hide()
                    saving = true
                    scope.launch {
                        val result = withContext(Dispatchers.IO) {
                            PhotoFrameExporter.exportBesideSource(
                                context = context,
                                resolver = context.contentResolver,
                                source = selectedSource,
                                preset = preset,
                                watermark = renderWatermark,
                                borderEnabled = decorationEnabled && borderEnabled,
                                filter = selectedFilter,
                            )
                        }
                        saving = false
                        result.fold(
                            onSuccess = { showHint(savedFormat.format(it.displayName)) },
                            onFailure = { showHint(saveFailedText) },
                        )
                    }
                },
                enabled = selection != null && hasEffect && !saving && !sourceLoading,
                active = selection != null && hasEffect,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(50.dp),
            ) {
                if (saving) {
                    CircularProgressIndicator(
                        color = colors.accentBlue,
                        strokeWidth = 2.dp,
                        modifier = Modifier.size(19.dp),
                    )
                } else {
                    Icon(
                        Icons.Default.Save,
                        contentDescription = null,
                        tint = colors.accentBlue,
                        modifier = Modifier.size(19.dp),
                    )
                }
                Text(
                    text = stringResource(
                        if (saving) R.string.local_photo_generating else R.string.local_photo_generate
                    ),
                    style = MaterialTheme.typography.labelLarge,
                    fontWeight = FontWeight.SemiBold,
                    color = colors.onBackground,
                )
            }
            Spacer(Modifier.height(7.dp))
            Text(
                text = stringResource(R.string.local_photo_same_folder_hint),
                style = MaterialTheme.typography.labelSmall,
                color = colors.onSurfaceVariant.copy(alpha = 0.82f),
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(18.dp))
        }
        AnimatedVisibility(
            visible = hintVisible,
            enter = fadeIn() + slideInVertically { it / 2 },
            exit = fadeOut() + slideOutVertically { it / 2 },
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .padding(bottom = 28.dp),
        ) {
            Surface(
                shape = RoundedCornerShape(18.dp),
                color = colors.glassSurfaceHeavy,
                shadowElevation = 6.dp,
                border = BorderStroke(1.dp, colors.glassPanelBorder),
            ) {
                Text(
                    text = hintText,
                    textAlign = TextAlign.Center,
                    style = MaterialTheme.typography.labelLarge,
                    color = colors.onBackground,
                    modifier = Modifier.padding(horizontal = 20.dp, vertical = 10.dp),
                )
            }
        }
    }
}
