package com.ztransfer.ui

import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.ztransfer.ui.screen.*
import com.ztransfer.ui.theme.AppTheme

/** Temporary settings host: only working preferences appear; the full workspace remains pending. */
@Composable
internal fun NativePhotoSettingsOverlay(model: NativeFilesPageModel, layout: NativeBrowseLayout,
    text: NativeSettingsPageText, anchor: Rect, appearance: NativeAppearanceModel, onDismiss: () -> Unit) {
    val appearanceState by appearance.state.collectAsState()
    val openingAnchor = remember { anchor }
    val density = LocalDensity.current
    val panelTop = with(density) { openingAnchor.bottom.toDp() } + 8.dp
    SharedAnchorPopup(anchorBounds = openingAnchor, onDismiss = onDismiss,
        panelModifier = Modifier.padding(start = 12.dp, end = 12.dp, top = panelTop).navigationBarsPadding().fillMaxWidth(),
        animateScale = false,
    ) { close ->
        Column(Modifier.verticalScroll(rememberScrollState()).padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(text.title, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold,
                    color = AppTheme.colors.onBackground)
                Spacer(Modifier.weight(1f))
                IconButton(onClick = close, modifier = Modifier.size(32.dp)) {
                    Icon(Icons.Default.Close, text.close, tint = AppTheme.colors.onSurfaceVariant)
                }
            }
            Spacer(Modifier.height(14.dp))
            SharedPhotoListSettingsCard(layout.columns, layout.collapseBursts, layout.tapToPreview, appearanceState.hapticsEnabled, text,
                onColumns = { model.changeLayout(it, model.layout.value.collapseBursts) },
                onCollapseBursts = { model.changeLayout(model.layout.value.columns, it) },
                onTapToPreview = model::setTapToPreview)
            Spacer(Modifier.height(14.dp))
            SharedAppearanceSettingsCard(appearanceState.theme, appearanceState.language, "system", appearanceState.skin,
                appearanceState.hapticsEnabled, appearanceState.keepScreenOn, text,
                onTheme = { appearance.setThemeName(it.name) }, onLanguage = appearance::setLanguage,
                onSkin = { appearance.setSkinName(it.name) }, onHaptics = appearance::setHapticsEnabled,
                onKeepScreenOn = appearance::setKeepScreenOn, close = close)
        }
    }
}
