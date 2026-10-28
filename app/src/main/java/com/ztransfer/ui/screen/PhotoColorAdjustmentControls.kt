package com.ztransfer.ui.screen

import androidx.compose.foundation.layout.*
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.draw.scale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ztransfer.R
import com.ztransfer.filter.LutAdjustments
import com.ztransfer.filter.DEFAULT_PHOTO_FILTER_INTENSITY_PERCENT
import com.ztransfer.filter.normalizePhotoFilterIntensity

private val PHOTO_COLOR_ADJUSTMENT_OPTIONS = (100 downTo -100 step 5).toList()

/** Show a restored valid value exactly, even when it lies between the usual five-step detents. */
internal fun photoColorAdjustmentOptions(selected: Int): List<Int> {
    require(selected in -100..100)
    return if (selected in PHOTO_COLOR_ADJUSTMENT_OPTIONS) PHOTO_COLOR_ADJUSTMENT_OPTIONS
    else (PHOTO_COLOR_ADJUSTMENT_OPTIONS + selected).sortedDescending()
}

/** The same disclosure control and finishing wheels serve both photo filters and LUTs. */
@Composable
internal fun PhotoColorAdjustmentButton(
    label: String,
    expanded: Boolean,
    enabled: Boolean,
    accentColor: Color,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    readOnly: Boolean = false,
) {
    ReleaseCommitWheel(
        options = listOf(Unit), selected = Unit, optionLabel = { label }, onValueCommitted = {},
        onActivated = onClick, modifier = modifier, wheelHeight = PHOTO_EFFECTS_CONTROL_HEIGHT,
        accentColor = accentColor, enabled = enabled, emphasized = expanded, showDragHint = false,
        readOnly = readOnly,
    )
}

@Composable
internal fun PhotoColorAdjustmentControls(
    intensityPercent: Int,
    adjustments: LutAdjustments,
    intensityLabel: String,
    accentColor: Color,
    enabled: Boolean,
    onIntensityChanged: (Int) -> Unit,
    onAdjustmentsChanged: (LutAdjustments) -> Unit,
    onDetent: () -> Unit,
    presetId: String? = null,
    readOnly: Boolean = false,
) {
    // Keep every wheel mounted when values change. Only its in-flight gesture belongs to
    // this exact parameter snapshot, so a reset/new preset cannot commit an old drag.
    val gestureKey = remember(presetId, intensityPercent, adjustments) { Any() }
    Column(Modifier.fillMaxWidth().padding(top = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            ReleaseCommitWheel(
                remember { (100 downTo 2 step 2).toList() }, normalizePhotoFilterIntensity(intensityPercent),
                optionLabel = { "$it%" }, onValueCommitted = onIntensityChanged,
                modifier = Modifier.weight(1f), label = intensityLabel,
                wheelHeight = 34.dp, cornerRadius = 10.dp, optionRowHeight = 16.dp,
                optionFontSize = 13.sp, accentColor = accentColor, enabled = enabled, onDetent = onDetent,
                readOnly = readOnly, gestureKey = gestureKey,
            )
            val resetLabel = stringResource(R.string.photo_color_reset)
            ReleaseCommitWheel(
                options = listOf(Unit), selected = Unit, optionLabel = { resetLabel },
                onValueCommitted = {}, onActivated = {
                    onDetent()
                    onIntensityChanged(DEFAULT_PHOTO_FILTER_INTENSITY_PERCENT)
                    onAdjustmentsChanged(LutAdjustments())
                },
                modifier = Modifier.width(38.dp), wheelHeight = 34.dp, cornerRadius = 10.dp,
                showDragHint = false, enabled = enabled, accentColor = accentColor,
                readOnly = readOnly, gestureKey = gestureKey,
                centerIcon = { PhotoColorResetIcon(it) }, showIconLabel = false,
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            ReleaseCommitWheel(
                remember(adjustments.contrast) { photoColorAdjustmentOptions(adjustments.contrast) },
                adjustments.contrast, optionLabel = { it.toString() },
                onValueCommitted = { onAdjustmentsChanged(adjustments.copy(contrast = it)) },
                modifier = Modifier.weight(1f), label = stringResource(R.string.photo_lut_contrast),
                wheelHeight = 34.dp, cornerRadius = 10.dp, optionRowHeight = 16.dp,
                optionFontSize = 13.sp, accentColor = accentColor, enabled = enabled, onDetent = onDetent,
                readOnly = readOnly, gestureKey = gestureKey,
            )
            ReleaseCommitWheel(
                remember(adjustments.saturation) { photoColorAdjustmentOptions(adjustments.saturation) },
                adjustments.saturation, optionLabel = { it.toString() },
                onValueCommitted = { onAdjustmentsChanged(adjustments.copy(saturation = it)) },
                modifier = Modifier.weight(1f), label = stringResource(R.string.photo_lut_saturation),
                wheelHeight = 34.dp, cornerRadius = 10.dp, optionRowHeight = 16.dp,
                optionFontSize = 13.sp, accentColor = accentColor, enabled = enabled, onDetent = onDetent,
                readOnly = readOnly, gestureKey = gestureKey,
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            ReleaseCommitWheel(
                remember(adjustments.highlights) { photoColorAdjustmentOptions(adjustments.highlights) },
                adjustments.highlights, optionLabel = { it.toString() },
                onValueCommitted = { onAdjustmentsChanged(adjustments.copy(highlights = it)) },
                modifier = Modifier.weight(1f), label = stringResource(R.string.photo_lut_highlights),
                wheelHeight = 34.dp, cornerRadius = 10.dp, optionRowHeight = 16.dp,
                optionFontSize = 13.sp, accentColor = accentColor, enabled = enabled, onDetent = onDetent,
                readOnly = readOnly, gestureKey = gestureKey,
            )
            ReleaseCommitWheel(
                remember(adjustments.shadows) { photoColorAdjustmentOptions(adjustments.shadows) },
                adjustments.shadows, optionLabel = { it.toString() },
                onValueCommitted = { onAdjustmentsChanged(adjustments.copy(shadows = it)) },
                modifier = Modifier.weight(1f), label = stringResource(R.string.photo_lut_shadows),
                wheelHeight = 34.dp, cornerRadius = 10.dp, optionRowHeight = 16.dp,
                optionFontSize = 13.sp, accentColor = accentColor, enabled = enabled, onDetent = onDetent,
                readOnly = readOnly, gestureKey = gestureKey,
            )
        }
    }
}

/** Reuse the monitor's rounded arrow, mirrored to mean returning to defaults. */
@Composable
private fun PhotoColorResetIcon(color: Color) {
    Icon(
        painter = painterResource(R.drawable.ic_monitor_rotate),
        contentDescription = null,
        tint = color,
        modifier = Modifier.size(20.dp).scale(scaleX = -1f, scaleY = 1f),
    )
}
