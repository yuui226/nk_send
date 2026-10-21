package com.ztransfer.ui.screen

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.runtime.Composable
import androidx.compose.runtime.key
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.ztransfer.R
import com.ztransfer.grain.PhotoGrainSettings
import com.ztransfer.grain.PhotoGrainStyle
import com.ztransfer.ui.theme.AppTheme
import com.ztransfer.ui.util.rememberHaptics

/** The same release-to-commit control is used by camera and phone photo editors. */
@Composable
internal fun PhotoGrainEditor(
    settings: PhotoGrainSettings,
    onStyleSelected: (PhotoGrainStyle?) -> Unit,
    onIntensityChanged: (PhotoGrainStyle, Int) -> Unit,
    hapticsEnabled: Boolean,
) {
    val colors = AppTheme.colors
    val haptics = rememberHaptics(hapticsEnabled)
    val normalized = settings.normalized()
    val levels = remember { (100 downTo 0).toList() }
    val styleOptions = remember { listOf(null) + PhotoGrainStyle.entries }
    val styleLabels = PhotoGrainStyle.entries.associateWith { photoGrainStyleLabel(it) }
    val offLabel = stringResource(R.string.setting_off)
    SettingsCard(borderColor = colors.accentBlue.copy(alpha = 0.24f), tintColor = colors.accentBlue) {
        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            ReleaseCommitWheel(
                options = styleOptions,
                selected = normalized.style.takeIf { normalized.enabled },
                optionLabel = { style -> if (style == null) offLabel else styleLabels.getValue(style) },
                onValueCommitted = onStyleSelected,
                onDetent = haptics::tick,
                label = stringResource(R.string.photo_grain),
                wheelHeight = PHOTO_EFFECTS_CONTROL_HEIGHT,
                accentColor = colors.accentBlue,
                modifier = Modifier.weight(PHOTO_COLOR_NAME_WEIGHT),
            )
            // A style change cancels any unfinished strength drag for the previous style.
            key(normalized.style) {
                ReleaseCommitWheel(
                    options = levels,
                    selected = normalized.intensityPercent,
                    optionLabel = { "$it%" },
                    onValueCommitted = {
                        onIntensityChanged(normalized.style, it)
                    },
                    onDetent = haptics::tick,
                    label = stringResource(R.string.photo_filter_intensity),
                    enabled = normalized.enabled,
                    wheelHeight = PHOTO_EFFECTS_CONTROL_HEIGHT,
                    accentColor = colors.accentBlue,
                    modifier = Modifier.weight(PHOTO_COLOR_INTENSITY_WEIGHT),
                )
            }
        }
    }
}

@Composable
internal fun photoGrainStyleLabel(style: PhotoGrainStyle): String = stringResource(
    when (style) {
        PhotoGrainStyle.FINE -> R.string.photo_grain_fine
        PhotoGrainStyle.MEDIUM -> R.string.photo_grain_medium
        PhotoGrainStyle.COARSE -> R.string.photo_grain_coarse
    },
)
