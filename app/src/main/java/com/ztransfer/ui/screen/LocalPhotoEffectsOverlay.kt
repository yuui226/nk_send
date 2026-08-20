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
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.ztransfer.R
import com.ztransfer.effects.FavoriteFrameWatermarkEffect
import com.ztransfer.effects.FavoritePhotoFilter
import com.ztransfer.filter.PhotoFilterSelection
import com.ztransfer.filter.BuiltInPhotoFilters
import com.ztransfer.frame.PhotoFrameExporter
import com.ztransfer.frame.PhotoFrameMediaStoreSource
import com.ztransfer.frame.PhotoFrameMetadata
import com.ztransfer.frame.PhotoFrameWatermark
import com.ztransfer.frame.PhotoFrameWatermarkContent
import com.ztransfer.frame.LOCAL_PHOTO_FALLBACK_RELATIVE_PATH
import com.ztransfer.frame.defaultPhotoFrameMetadataSettings
import com.ztransfer.frame.normalizePhotoFrameMetadataSettings
import com.ztransfer.frame.resolvedPhotoFrameMetadataSettings
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
    val pageTopInset = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()

    val settingsPreferences = remember(context) { LocalPhotoEffectsPreferences(context) }
    val availableFilterIds = state.photoFilters.map { it.id }
    val initialSettings = remember(settingsPreferences, availableFilterIds) {
        settingsPreferences.restore(availableFilterIds)
    }

    var selection by remember { mutableStateOf<LocalPhotoSelection?>(null) }
    var sourceLoading by remember { mutableStateOf(false) }
    var saving by remember { mutableStateOf(false) }
    var watermarkImageImporting by remember { mutableStateOf(false) }
    var showPhotoEffectsInfo by remember { mutableStateOf(false) }
    var photoEffectsInfoViewed by remember { mutableStateOf(false) }
    var photoEffectsInfoAnchorBounds by remember { mutableStateOf<Rect?>(null) }

    var decorationEnabled by remember { mutableStateOf(initialSettings.decorationEnabled) }
    var borderEnabled by remember { mutableStateOf(initialSettings.borderEnabled) }
    var preset by remember { mutableStateOf(initialSettings.preset) }
    var metadataSettings by remember { mutableStateOf(initialSettings.metadataSettings) }
    var watermarkDraft by remember { mutableStateOf(initialSettings.watermark) }
    var filterId by remember { mutableStateOf(initialSettings.filterId) }
    var filterEnabled by remember { mutableStateOf(initialSettings.filterEnabled) }
    var filterIntensity by remember {
        mutableIntStateOf(initialSettings.filterIntensityPercent)
    }
    var filterIntensities by remember { mutableStateOf(initialSettings.filterIntensities) }
    var favoritePhotoFilters by remember {
        mutableStateOf(initialSettings.favoritePhotoFilters)
    }
    var favoriteFrameEffects by remember {
        mutableStateOf(initialSettings.favoriteFrameEffects)
    }
    val currentSettings = LocalPhotoEffectsSettings(
        decorationEnabled = decorationEnabled,
        borderEnabled = borderEnabled,
        preset = preset,
        metadataSettings = metadataSettings,
        watermark = watermarkDraft,
        filterId = filterId,
        filterEnabled = filterEnabled,
        filterIntensityPercent = filterIntensity,
        filterIntensities = filterIntensities,
        favoritePhotoFilters = favoritePhotoFilters,
        favoriteFrameEffects = favoriteFrameEffects,
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
    val watermarkFavoriteImageMissingText =
        stringResource(R.string.photo_effect_favorite_image_missing)
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
    val launchPhotoPicker = {
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
                    )
                    decorationEnabled = borderEnabled || watermarkDraft.enabled
                    if (borderEnabled) {
                        viewModel.updateFavoriteFrameEffect(preset, watermarkDraft)
                    }
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
        isPro -> watermarkDraft.withEditorPlacementConstraints(
            borderEnabled = decorationEnabled && borderEnabled,
        )
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
                .clearFocusOnBackgroundTap(enabled = true) {
                    focusManager.clearFocus()
                }
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
                TipLightbulbButton(
                    onClick = {
                        photoEffectsInfoViewed = true
                        showPhotoEffectsInfo = true
                    },
                    contentDescription = stringResource(R.string.photo_effects_info_title),
                    attention = !photoEffectsInfoViewed,
                    modifier = Modifier
                        .size(38.dp)
                        .onGloballyPositioned {
                            photoEffectsInfoAnchorBounds = it.boundsInRoot()
                        },
                )
                Spacer(Modifier.width(8.dp))
                GlassButton(
                    onClick = launchPhotoPicker,
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
            val previewFilterPrefetch = remember(
                state.photoFilters,
                favoritePhotoFilters,
                filterIntensities,
                filterId,
                filterEnabled,
            ) {
                nextPhotoFilterSelections(
                    filters = state.photoFilters,
                    favoriteCatalogKeys = favoritePhotoFilters.map { it.catalogKey },
                    rememberedIntensities = filterIntensities,
                    selectedId = filterId,
                    enabled = filterEnabled,
                )
            }
            if (previewBitmap == null) {
                Surface(
                    onClick = launchPhotoPicker,
                    enabled = !sourceLoading && !saving,
                    shape = RoundedCornerShape(12.dp),
                    color = colors.onBackground.copy(alpha = 0.035f),
                    border = BorderStroke(1.dp, colors.glassPanelBorder),
                    modifier = Modifier
                        .fillMaxWidth()
                        .aspectRatio(4f / 3f),
                ) {
                    Box(
                        contentAlignment = Alignment.Center,
                        modifier = Modifier.fillMaxSize(),
                    ) {
                        Text(
                            text = stringResource(R.string.local_photo_choose_short),
                            style = MaterialTheme.typography.labelLarge,
                            color = colors.accentBlue,
                        )
                    }
                }
            } else {
                PhotoEffectsRenderedPreview(
                    source = previewBitmap,
                    resetOnSourceChange = true,
                    metadata = selection?.metadata ?: PhotoFrameMetadata(
                        make = null,
                        model = null,
                        aperture = null,
                        shutter = null,
                        iso = null,
                        focalLength = null,
                        lensModel = null,
                    ),
                    sourceRotationQuarterTurns = 0,
                    requestedRotationQuarterTurns = 0,
                    requestedPortrait = previewBitmap.height > previewBitmap.width,
                    onRotate = null,
                    borderEnabled = decorationEnabled && borderEnabled,
                    preset = preset,
                    metadataSettings = resolvedPhotoFrameMetadataSettings(
                        metadataSettings,
                        preset,
                    ),
                    watermark = renderWatermark,
                    filter = selectedFilter,
                    prefetchFilters = previewFilterPrefetch,
                    onOpen = null,
                )
            }

            Spacer(Modifier.height(10.dp))
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
                                metadataSettings = resolvedPhotoFrameMetadataSettings(
                                    metadataSettings,
                                    preset,
                                ),
                                filter = selectedFilter,
                            )
                        }
                        saving = false
                        result.fold(
                            onSuccess = { exportResult ->
                                val savedDirectory = exportResult.relativePath
                                    ?.trimEnd('/', '\\')
                                    ?.takeIf(String::isNotBlank)
                                    ?: LOCAL_PHOTO_FALLBACK_RELATIVE_PATH
                                showHint(savedFormat.format(savedDirectory))
                            },
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

            Spacer(Modifier.height(10.dp))
            PhotoFilterEditor(
                filters = state.photoFilters,
                favoriteFilters = favoritePhotoFilters,
                rememberedIntensities = filterIntensities,
                selectedId = filterId,
                enabled = filterEnabled,
                intensityPercent = filterIntensity,
                onDisabled = { filterEnabled = false },
                onSelected = {
                    filterId = it
                    filterEnabled = true
                },
                onIntensityChanged = { selectedFilterId, intensity ->
                    filterIntensity = intensity
                    val catalogKey = BuiltInPhotoFilters.catalogKey(selectedFilterId)
                        ?: selectedFilterId
                    filterIntensities = filterIntensities + (catalogKey to intensity)
                },
                onFavoriteToggled = { selectedFilterId ->
                    BuiltInPhotoFilters.catalogKey(selectedFilterId)?.let { catalogKey ->
                        favoritePhotoFilters = if (
                            favoritePhotoFilters.any { it.catalogKey == catalogKey }
                        ) {
                            favoritePhotoFilters.filterNot { it.catalogKey == catalogKey }
                        } else {
                            favoritePhotoFilters + FavoritePhotoFilter(catalogKey)
                        }
                    }
                },
                hapticsEnabled = state.hapticsEnabled,
            )
            Spacer(Modifier.height(10.dp))
            PhotoFrameWatermarkEditor(
                favoriteEffects = favoriteFrameEffects,
                borderEnabled = decorationEnabled && borderEnabled,
                preset = preset,
                metadataSettings = resolvedPhotoFrameMetadataSettings(
                    metadataSettings,
                    preset,
                ),
                previewMetadata = selection?.metadata,
                watermark = editorWatermark,
                watermarkContentSource = watermarkDraft,
                isPro = isPro,
                hapticsEnabled = state.hapticsEnabled,
                onBorderEnabledChanged = { enabled ->
                    borderEnabled = enabled
                    decorationEnabled = enabled || (isPro && watermarkDraft.enabled)
                },
                onPresetChanged = { preset = it },
                onMetadataSettingsChanged = { updated ->
                    val normalized = normalizePhotoFrameMetadataSettings(updated)
                    metadataSettings = if (
                        normalized == defaultPhotoFrameMetadataSettings(preset)
                    ) {
                        metadataSettings - preset
                    } else {
                        metadataSettings + (preset to normalized)
                    }
                },
                onWatermarkChanged = { updated ->
                    if (isPro) {
                        watermarkDraft = mergeWatermarkEditKeepingPreferredPosition(
                            preferred = watermarkDraft,
                            edited = updated,
                        )
                        decorationEnabled = borderEnabled || updated.enabled
                    }
                },
                onFavoriteWatermarkApplied = { favoriteWatermark ->
                    if (isPro) {
                        watermarkDraft = favoriteWatermark
                        decorationEnabled = borderEnabled || favoriteWatermark.enabled
                    }
                },
                onWatermarkPositionChanged = { position ->
                    if (isPro) watermarkDraft = watermarkDraft.copy(position = position)
                },
                onWatermarkTextCommitted = { text ->
                    if (isPro) watermarkDraft = watermarkDraft.copy(text = text)
                },
                imageImporting = watermarkImageImporting,
                onFavoriteToggled = { favoritePreset, favoriteWatermark ->
                    favoriteFrameEffects = if (
                        favoriteFrameEffects.any { it.framePreset == favoritePreset }
                    ) {
                        favoriteFrameEffects.filterNot { it.framePreset == favoritePreset }
                    } else {
                        favoriteFrameEffects + FavoriteFrameWatermarkEffect.capture(
                            favoritePreset,
                            favoriteWatermark,
                        )
                    }
                },
                onFavoriteUpdated = { favoritePreset, favoriteWatermark ->
                    favoriteFrameEffects = favoriteFrameEffects.map { favorite ->
                        if (favorite.framePreset == favoritePreset) {
                            FavoriteFrameWatermarkEffect.capture(
                                favoritePreset,
                                favoriteWatermark,
                            )
                        } else {
                            favorite
                        }
                    }
                },
                onFavoriteImageMissing = {
                    showHint(watermarkFavoriteImageMissingText)
                },
                onProRequired = { showHint(watermarkProOnlyText) },
                onImageRequested = {
                    if (isPro && !watermarkImageImporting) {
                        watermarkImagePicker.launch(
                            PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)
                        )
                    }
                },
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
        if (showPhotoEffectsInfo) {
            PhotoEffectsInfoBubble(
                anchorBounds = photoEffectsInfoAnchorBounds,
                onDismiss = { showPhotoEffectsInfo = false },
                description = stringResource(R.string.local_photo_effects_info_description),
                gestureHint = stringResource(R.string.local_photo_effects_gesture_hint),
                extraHints = listOf(
                    stringResource(R.string.local_photo_effects_exif_hint),
                    stringResource(R.string.local_photo_same_folder_hint),
                ),
                parentTopInset = pageTopInset,
            )
        }
    }
}
