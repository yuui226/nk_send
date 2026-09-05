"""Reproducible extraction of original settings cards; no IO, licenses or effect editor moves."""
import re
import textwrap
from thumbnail_grid_extraction import section
from transfer_card_extraction import replace_once

BASELINE = 'a478ffe'
ANDROID = 'app/src/main/java/com/ztransfer/ui/screen/SettingsScreen.kt'
COMMON = 'shared/src/commonMain/kotlin/com/ztransfer/ui/screen/SharedSettingsControls.kt'
HEADER = '''@file:OptIn(kotlin.experimental.ExperimentalObjCRefinement::class)

package com.ztransfer.ui.screen

import androidx.compose.animation.core.*
import androidx.compose.foundation.*
import androidx.compose.foundation.interaction.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.*
import com.ztransfer.ui.theme.*
import com.ztransfer.ui.util.rememberHaptics

'''
CARD_SIGNATURES = [
'''fun SharedTransferDirectorySettingsCard(
    dirText: String?, hasDirectory: Boolean, directoryAttentionActive: Boolean, attentionProgress: Float,
    organizeByDate: Boolean, autoTransfer: Boolean, deferStart: Boolean, hapticsEnabled: Boolean,
    text: SettingsControlsText, selectDirectory: () -> Unit,
    onOrganizeByDate: (Boolean) -> Unit, onAutoTransfer: (Boolean) -> Unit, onDeferStart: (Boolean) -> Unit,
)''',
'''fun SharedPhotoListSettingsCard(
    columns: Int, collapseBursts: Boolean, tapToPreview: Boolean, hapticsEnabled: Boolean,
    text: SettingsControlsText, onColumns: (Int) -> Unit,
    onCollapseBursts: (Boolean) -> Unit, onTapToPreview: (Boolean) -> Unit,
)''',
'''fun SharedAppearanceSettingsCard(
    themeMode: ThemeMode, appLanguage: String, systemLanguageValue: String, skinPreset: SkinPreset,
    hapticsEnabled: Boolean, keepScreenOn: Boolean, text: SettingsControlsText,
    onTheme: (ThemeMode) -> Unit, onLanguage: (String) -> Unit, onSkin: (SkinPreset) -> Unit,
    onHaptics: (Boolean) -> Unit, onKeepScreenOn: (Boolean) -> Unit, close: () -> Unit,
)''',
]
CALLS = [
'''            SharedTransferDirectorySettingsCard(
                dirText = dirText, hasDirectory = state.transferDirUri != null,
                directoryAttentionActive = directoryAttentionActive, attentionProgress = directoryAttentionProgress.value,
                organizeByDate = state.organizeTransfersByDate, autoTransfer = state.autoTransferNewMedia,
                deferStart = state.deferTransferStart, hapticsEnabled = state.hapticsEnabled,
                text = AndroidSettingsControlsText, selectDirectory = { directoryPicker.launch(null) },
                onOrganizeByDate = viewModel::setOrganizeTransfersByDate,
                onAutoTransfer = viewModel::setAutoTransferNewMedia, onDeferStart = viewModel::setDeferTransferStart,
            )
''',
'''            SharedPhotoListSettingsCard(
                columns = state.thumbnailColumns, collapseBursts = state.collapseBurstPhotos,
                tapToPreview = state.tapToPreview, hapticsEnabled = state.hapticsEnabled,
                text = AndroidSettingsControlsText, onColumns = viewModel::setThumbnailColumns,
                onCollapseBursts = viewModel::setCollapseBurstPhotos, onTapToPreview = viewModel::setTapToPreview,
            )
''',
'''            SharedAppearanceSettingsCard(
                themeMode = state.themeMode, appLanguage = state.appLanguage, systemLanguageValue = AppLocale.SYSTEM,
                skinPreset = state.skinPreset, hapticsEnabled = state.hapticsEnabled, keepScreenOn = state.keepScreenOn,
                text = AndroidSettingsControlsText, onTheme = viewModel::setThemeMode,
                onLanguage = viewModel::setAppLanguage, onSkin = viewModel::setSkinPreset,
                onHaptics = viewModel::setHapticsEnabled, onKeepScreenOn = viewModel::setKeepScreenOn, close = close,
            )
''',
]

def extract(source):
    android = source
    helpers = []
    for name, end, args in [
        ('SettingsCard', '\n/** 卡片内子项', 'modifier, borderColor, tintColor, pressAccentColor, attentionColor, attentionProgress, enabled, onClick, content'),
        ('CardDivider', '\n/**\n * 页脚版本', ''),
        ('SectionLabel', None, 'text, modifier, color'),
        ('BooleanSettingsWheel', '\nprivate val BOOLEAN_SETTINGS_OPTIONS',
         'label, checked, onCheckedChange, hapticsEnabled, modifier, enabled, isHapticsPreference, compact, AndroidSettingsControlsText'),
    ]:
        start = '@Composable\nprivate fun ' + name + '('
        original = section(source, start, end) if end else source[source.index(start):]
        signature = original[:original.index(' {')]
        wrapper = signature + ' {\n    Shared' + name + '(' + args + ')\n}\n'
        android = replace_once(android, original, wrapper)
        shared = original.replace('private fun ' + name, 'fun Shared' + name, 1)
        if name == 'BooleanSettingsWheel':
            shared = replace_once(shared, '    compact: Boolean = false,', '    compact: Boolean = false,\n    text: SettingsControlsText,')
            shared = shared.replace('stringResource(', 'text.label(').replace('R.string.', 'SettingsTextKey.')
        helpers.append('@kotlin.native.HiddenFromObjC\n' + shared)

    constants = section(source, 'private val BOOLEAN_SETTINGS_OPTIONS', '\ninternal enum class GpsStatusButtonState')
    # GPS still uses these dimensions. Its Android references are aliases to the same shared values.
    aliases = []
    for old, new in [('COMPACT_SETTINGS_WHEEL_HEIGHT', 'SettingsCompactWheelHeight'),
                     ('COMPACT_SETTINGS_WHEEL_ROW_HEIGHT', 'SettingsCompactWheelRowHeight'),
                     ('COMPACT_SETTINGS_WHEEL_FONT_SIZE', 'SettingsCompactWheelFontSize')]:
        aliases.append('private val ' + old + ' = ' + new)
        constants = constants.replace('private val ' + old, '@kotlin.native.HiddenFromObjC\nval ' + new)
    android = replace_once(android, section(source, 'private val BOOLEAN_SETTINGS_OPTIONS', '\ninternal enum class GpsStatusButtonState'), '\n'.join(aliases) + '\n')

    cards = []
    for index, (start, end) in enumerate([
        ('            // ---------- 传输目录：', '\n            Spacer(Modifier.height(8.dp))'),
        ('            // ---------- 照片列表：', '\n            Spacer(Modifier.height(8.dp))'),
        ('            // ---------- 明暗、语言、按钮材质：', '\n            Spacer(Modifier.height(14.dp))'),
    ]):
        begin = source.index(start)
        original = source[begin:source.index(end, begin)]
        android = replace_once(android, original, CALLS[index])
        body = textwrap.indent(textwrap.dedent(original).rstrip(), '    ')
        body = body.replace('directoryAttentionProgress.value', 'attentionProgress')
        body = body.replace('state.transferDirUri != null', 'hasDirectory').replace('directoryPicker.launch(null)', 'selectDirectory()')
        body = body.replace('AppLocale.SYSTEM', 'systemLanguageValue')
        body = body.replace('stringResource(skin.displayNameResId)', 'text.skinLabel(skin)')
        body = body.replace('stringResource(', 'text.label(').replace('R.string.', 'SettingsTextKey.')
        for old, new in {
            'state.organizeTransfersByDate': 'organizeByDate', 'state.autoTransferNewMedia': 'autoTransfer',
            'state.deferTransferStart': 'deferStart', 'state.thumbnailColumns': 'columns',
            'state.collapseBurstPhotos': 'collapseBursts', 'state.tapToPreview': 'tapToPreview',
            'state.hapticsEnabled': 'hapticsEnabled', 'state.keepScreenOn': 'keepScreenOn',
            'state.themeMode': 'themeMode', 'state.appLanguage': 'appLanguage', 'state.skinPreset': 'skinPreset',
            'viewModel::setOrganizeTransfersByDate': 'onOrganizeByDate', 'viewModel::setAutoTransferNewMedia': 'onAutoTransfer',
            'viewModel::setDeferTransferStart': 'onDeferStart', 'viewModel::setThumbnailColumns': 'onColumns',
            'viewModel::setCollapseBurstPhotos': 'onCollapseBursts', 'viewModel.setTapToPreview': 'onTapToPreview',
            'viewModel.setThemeMode': 'onTheme', 'viewModel.setAppLanguage': 'onLanguage', 'viewModel.setSkinPreset': 'onSkin',
            'viewModel::setHapticsEnabled': 'onHaptics', 'viewModel::setKeepScreenOn': 'onKeepScreenOn',
        }.items():
            body = body.replace(old, new)
        body = body.replace('SettingsCard', 'SharedSettingsCard').replace('CardDivider()', 'SharedCardDivider()').replace('SectionLabel(', 'SharedSectionLabel(')
        body = re.sub(r'(?m)^([ \t]*)BooleanSettingsWheel\(',
                      lambda m: m[1] + 'SharedBooleanSettingsWheel(\n' + m[1] + '    text = text,', body)
        inputs = '    val colors = AppTheme.colors\n' if index == 0 else '    val haptics = rememberHaptics(hapticsEnabled)\n'
        cards.append('@kotlin.native.HiddenFromObjC\n@Composable\n' + CARD_SIGNATURES[index] + ' {\n' + inputs + body + '\n}\n')

    shared = '\n'.join(helpers + [constants] + cards)
    for old, new in [('COMPACT_SETTINGS_WHEEL_HEIGHT', 'SettingsCompactWheelHeight'),
                     ('COMPACT_SETTINGS_WHEEL_ROW_HEIGHT', 'SettingsCompactWheelRowHeight'),
                     ('COMPACT_SETTINGS_WHEEL_FONT_SIZE', 'SettingsCompactWheelFontSize')]:
        shared = shared.replace(old, new)
    keys = sorted(set(re.findall(r'SettingsTextKey\.(\w+)', shared)))
    contract = '@kotlin.native.HiddenFromObjC\nenum class SettingsTextKey { ' + ', '.join(keys) + ' }\n\n'
    contract += '''@kotlin.native.HiddenFromObjC
interface SettingsControlsText {
    @Composable fun label(key: SettingsTextKey): String
    @Composable fun skinLabel(skin: SkinPreset): String
}

'''
    adapter = '''
/** Android keeps the original resource and skin-label resolution. */
private object AndroidSettingsControlsText : SettingsControlsText {
    @Composable override fun label(key: SettingsTextKey): String = stringResource(when (key) {
'''
    adapter += ''.join('        SettingsTextKey.' + key + ' -> R.string.' + key + '\n' for key in keys)
    adapter += '''    })
    @Composable override fun skinLabel(skin: SkinPreset): String = stringResource(skin.displayNameResId)
}
'''
    return android.rstrip() + '\n' + adapter, HEADER + contract + shared.rstrip() + '\n'
