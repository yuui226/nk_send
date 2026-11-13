package com.ztransfer.ui.screen

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Tune
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.ztransfer.R
import com.ztransfer.effects.*
import com.ztransfer.ui.theme.AppTheme
import com.ztransfer.ui.util.rememberHaptics

@Composable
internal fun PhotoEffectModuleButton(onClick: () -> Unit, modifier: Modifier = Modifier) {
    // Measure the fixed slot, not Surface's changing pressed/minimum-touch bounds.
    Box(modifier = modifier, contentAlignment = Alignment.Center, propagateMinConstraints = true) {
        GlassButton(onClick = onClick, contentPadding = PaddingValues(0.dp), modifier = Modifier) {
            Icon(Icons.Outlined.Tune, stringResource(R.string.photo_effect_modules),
                Modifier.size(19.dp), tint = AppTheme.colors.onBackground)
        }
    }
}

@Composable
internal fun PhotoEffectModuleMenu(
    mask: Int,
    anchor: Rect?,
    isPro: Boolean,
    onChange: (Int) -> Unit,
    onDismiss: () -> Unit,
    hapticsEnabled: Boolean,
    parentTopInset: Dp = 0.dp,
) {
    val density = LocalDensity.current
    val top = anchor?.let { with(density) { it.bottom.toDp() } - parentTopInset + 8.dp } ?: 64.dp
    val haptics = rememberHaptics(hapticsEnabled)
    AnchorPopup(anchorBounds = anchor, onDismiss = onDismiss, dim = false,
        panelAlignment = Alignment.TopEnd,
        shape = RoundedCornerShape(18.dp),
        panelModifier = Modifier.padding(start = 18.dp, end = 18.dp, top = top)
            .widthIn(max = 156.dp),
    ) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            PhotoEffectModule.entries.forEach { module ->
                FilterChip(
                    label = stringResource(when (module) {
                        PhotoEffectModule.FILTER -> R.string.photo_effect_module_filter
                        PhotoEffectModule.LUT -> R.string.photo_effect_module_lut
                        PhotoEffectModule.GRAIN -> R.string.photo_grain
                        PhotoEffectModule.FRAME -> R.string.photo_effect_module_frame
                        PhotoEffectModule.WATERMARK -> R.string.photo_effect_module_watermark
                    }),
                    selected = mask.showsPhotoEffect(module),
                    onClick = {
                        val next = togglePhotoEffectModule(mask, module, isPro)
                        if (next != mask) { haptics.tick(); onChange(next) }
                    },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }
    }
}
