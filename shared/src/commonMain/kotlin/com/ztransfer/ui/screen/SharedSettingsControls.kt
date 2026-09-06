@file:OptIn(kotlin.experimental.ExperimentalObjCRefinement::class)

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

@kotlin.native.HiddenFromObjC
enum class SettingsTextKey { auto_transfer_new_media, button_style, change_directory, choose_directory, collapse_burst_photos, columns, defer_transfer_start, dir_not_set, dir_please_set, haptic_feedback, keep_screen_on, language, language_system, light_dark_mode, organize_transfers_by_date, photo_interaction, setting_off, setting_on, tap_preview_hold_transfer, tap_transfer_hold_preview, theme_dark, theme_light, theme_system, transfer_directory }

@kotlin.native.HiddenFromObjC
interface SettingsControlsText {
    @Composable fun label(key: SettingsTextKey): String
    @Composable fun skinLabel(skin: SkinPreset): String
}

@kotlin.native.HiddenFromObjC
@Composable
fun SharedSettingsCard(
    modifier: Modifier = Modifier,
    borderColor: Color = AppTheme.colors.glassPanelBorder,
    tintColor: Color? = null,
    pressAccentColor: Color? = null,
    attentionColor: Color? = null,
    attentionProgress: Float = 0f,
    enabled: Boolean = true,
    onClick: (() -> Unit)? = null,
    content: @Composable ColumnScope.() -> Unit
) {
    val shape = RoundedCornerShape(14.dp)
    val interactionSource = remember { MutableInteractionSource() }
    val pressed by interactionSource.collectIsPressedAsState()
    val enhancedPress = pressAccentColor != null
    val pressScale by animateFloatAsState(
        targetValue = if (pressed && enabled && onClick != null) {
            if (enhancedPress) 0.982f else 0.992f
        } else {
            1f
        },
        animationSpec = if (pressed) tween(80) else Motion.bouncy(),
        label = "settingsCardPress",
    )
    val pressProgress by animateFloatAsState(
        targetValue = if (pressed && enabled && onClick != null && enhancedPress) 1f else 0f,
        animationSpec = if (pressed) tween(90) else Motion.bouncy(),
        label = "settingsCardPressHighlight",
    )
    val normalizedAttention = attentionProgress.coerceIn(0f, 1f)
    val effectiveBorderColor = when {
        pressAccentColor != null && pressProgress > 0f -> pressAccentColor.copy(
            alpha = 0.52f + 0.30f * pressProgress,
        )
        attentionColor != null -> attentionColor.copy(
            alpha = 0.72f + 0.26f * normalizedAttention,
        )
        else -> borderColor
    }
    val effectiveBorderWidth = when {
        pressProgress > 0f -> 1f + 0.45f * pressProgress
        attentionColor != null -> 1.25f + 0.75f * normalizedAttention
        else -> 1f
    }
    Column(
        modifier = modifier
            .fillMaxWidth()
            .graphicsLayer {
                scaleX = pressScale
                scaleY = pressScale
            }
            .clip(shape)
            .then(
                if (onClick != null) {
                    Modifier.clickable(
                        enabled = enabled,
                        interactionSource = interactionSource,
                        indication = null,
                        onClick = onClick,
                    )
                } else {
                    Modifier
                }
            )
            // onBackground 极低透明度：深色主题下是白色微提亮、浅色下是黑色微压暗，两套都成立。
            .background(AppTheme.colors.onBackground.copy(alpha = 0.04f))
            .then(
                tintColor?.let { accent ->
                    Modifier.background(accent.copy(alpha = 0.040f))
                } ?: Modifier
            )
            .then(
                attentionColor?.let { accent ->
                    Modifier.background(
                        accent.copy(alpha = 0.055f + 0.075f * normalizedAttention)
                    )
                } ?: Modifier
            )
            .then(
                pressAccentColor?.let { accent ->
                    Modifier.background(accent.copy(alpha = 0.10f * pressProgress))
                } ?: Modifier
            )
            .border(
                width = effectiveBorderWidth.dp,
                color = effectiveBorderColor,
                shape = shape,
            )
            .padding(12.dp),
        content = content
    )
}

@kotlin.native.HiddenFromObjC
@Composable
fun SharedCardDivider() {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 8.dp)
            .height(1.dp)
            .background(AppTheme.colors.glassPanelBorder)
    )
}

@kotlin.native.HiddenFromObjC
@Composable
fun SharedSectionLabel(
    text: String,
    modifier: Modifier = Modifier,
    color: Color = AppTheme.colors.onBackground,
) {
    Text(
        text,
        modifier = modifier,
        style = MaterialTheme.typography.titleSmall,
        fontWeight = FontWeight.SemiBold,
        color = color,
    )
}

@kotlin.native.HiddenFromObjC
@Composable
fun SharedBooleanSettingsWheel(
    label: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    hapticsEnabled: Boolean,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    isHapticsPreference: Boolean = false,
    compact: Boolean = false,
    text: SettingsControlsText,
) {
    val colors = AppTheme.colors
    val wheelHaptics = rememberHaptics(hapticsEnabled || isHapticsPreference)
    val offLabel = text.label(SettingsTextKey.setting_off)
    val onLabel = text.label(SettingsTextKey.setting_on)
    ReleaseCommitWheel(
        options = BOOLEAN_SETTINGS_OPTIONS,
        selected = checked,
        optionLabel = { value -> if (value) onLabel else offLabel },
        onValueCommitted = onCheckedChange,
        onDetent = wheelHaptics::tick,
        label = label,
        accentColor = if (checked) colors.accentBlue else colors.statusWaiting,
        emphasized = checked,
        wheelHeight = if (compact) {
            SettingsCompactWheelHeight
        } else {
            BOOLEAN_SETTINGS_WHEEL_HEIGHT
        },
        optionRowHeight = if (compact) SettingsCompactWheelRowHeight else 18.dp,
        optionFontSize = if (compact) SettingsCompactWheelFontSize else 14.sp,
        modifier = modifier,
        enabled = enabled,
    )
}

private val BOOLEAN_SETTINGS_OPTIONS = listOf(false, true)
private val BOOLEAN_SETTINGS_WHEEL_HEIGHT = 50.dp
@kotlin.native.HiddenFromObjC
val SettingsCompactWheelHeight = 42.dp
@kotlin.native.HiddenFromObjC
val SettingsCompactWheelRowHeight = 16.dp
@kotlin.native.HiddenFromObjC
val SettingsCompactWheelFontSize = 13.sp
private const val APPEARANCE_COMPACT_WHEEL_WEIGHT = 3f
private const val BUTTON_STYLE_WHEEL_WEIGHT = 4f
private val PHOTO_COLUMN_OPTIONS = listOf(2, 3, 4)

@kotlin.native.HiddenFromObjC
@Composable
fun SharedTransferDirectoryHeader(dirText: String?, directoryAttentionActive: Boolean,
    text: SettingsControlsText, selectDirectory: () -> Unit) {
    val colors = AppTheme.colors
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(
            Icons.Default.LocationOn,
            contentDescription = null,
            tint = if (dirText != null) colors.statusConnected else colors.accentOrange,
            modifier = Modifier.size(18.dp)
        )
        Spacer(Modifier.width(10.dp))
        Column(modifier = Modifier.weight(1f)) {
            SharedSectionLabel(text.label(SettingsTextKey.transfer_directory))
            Text(
                text = dirText ?: text.label(
                    if (directoryAttentionActive) {
                        SettingsTextKey.dir_please_set
                    } else {
                        SettingsTextKey.dir_not_set
                    }
                ),
                style = if (directoryAttentionActive) {
                    MaterialTheme.typography.labelLarge
                } else {
                    MaterialTheme.typography.bodySmall
                },
                fontWeight = if (directoryAttentionActive) {
                    FontWeight.Bold
                } else {
                    FontWeight.Normal
                },
                color = if (dirText != null) colors.onSurfaceVariant else colors.accentOrange,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Spacer(Modifier.width(10.dp))
        GlassButton(
            onClick = { selectDirectory() },
            shape = RoundedCornerShape(12.dp),
            contentPadding = PaddingValues(horizontal = 12.dp),
            modifier = Modifier.height(30.dp)
        ) {
            Text(
                text.label(if (dirText != null) SettingsTextKey.change_directory else SettingsTextKey.choose_directory),
                style = MaterialTheme.typography.labelMedium,
                fontWeight = FontWeight.SemiBold,
                color = colors.onBackground
            )
        }
    }
}

@kotlin.native.HiddenFromObjC
@Composable
fun SharedTransferDirectorySettingsCard(
    dirText: String?, hasDirectory: Boolean, directoryAttentionActive: Boolean, attentionProgress: Float,
    organizeByDate: Boolean, autoTransfer: Boolean, deferStart: Boolean, hapticsEnabled: Boolean,
    text: SettingsControlsText, selectDirectory: () -> Unit,
    onOrganizeByDate: (Boolean) -> Unit, onAutoTransfer: (Boolean) -> Unit, onDeferStart: (Boolean) -> Unit,
) {
    val colors = AppTheme.colors
    // ---------- 传输目录：标题、单行路径与更改按钮并排；未设置时保留橙色强调 ----------
    SharedSettingsCard(
        modifier = Modifier.graphicsLayer {
            val scale = 1f + attentionProgress * 0.008f
            scaleX = scale
            scaleY = scale
        },
        borderColor = if (dirText == null) {
            colors.accentOrange.copy(alpha = 0.8f)
        } else {
            colors.glassPanelBorder
        },
        attentionColor = colors.accentOrange.takeIf { directoryAttentionActive },
        attentionProgress = attentionProgress,
    ) {
        SharedTransferDirectoryHeader(dirText, directoryAttentionActive, text, selectDirectory)

        SharedCardDivider()

        Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.fillMaxWidth(),
        ) {
            SharedBooleanSettingsWheel(
                text = text,
                label = text.label(SettingsTextKey.organize_transfers_by_date),
                checked = organizeByDate,
                onCheckedChange = onOrganizeByDate,
                hapticsEnabled = hapticsEnabled,
                enabled = hasDirectory,
                modifier = Modifier.weight(1f),
            )
            SharedBooleanSettingsWheel(
                text = text,
                label = text.label(SettingsTextKey.auto_transfer_new_media),
                checked = autoTransfer,
                onCheckedChange = onAutoTransfer,
                hapticsEnabled = hapticsEnabled,
                enabled = hasDirectory,
                modifier = Modifier.weight(1f),
            )
            SharedBooleanSettingsWheel(
                text = text,
                label = text.label(SettingsTextKey.defer_transfer_start),
                checked = deferStart,
                onCheckedChange = onDeferStart,
                hapticsEnabled = hapticsEnabled,
                enabled = hasDirectory,
                modifier = Modifier.weight(1f),
            )
        }
    }
}

@kotlin.native.HiddenFromObjC
@Composable
fun SharedPhotoListSettingsCard(
    columns: Int, collapseBursts: Boolean, tapToPreview: Boolean, hapticsEnabled: Boolean,
    text: SettingsControlsText, onColumns: (Int) -> Unit,
    onCollapseBursts: (Boolean) -> Unit, onTapToPreview: (Boolean) -> Unit,
) {
    val haptics = rememberHaptics(hapticsEnabled)
    // ---------- 照片列表：布局和操作方式 ----------
    val photoInteractionChoices = listOf(
        false to text.label(SettingsTextKey.tap_transfer_hold_preview),
        true to text.label(SettingsTextKey.tap_preview_hold_transfer),
    )
    SharedSettingsCard {
        Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.fillMaxWidth(),
        ) {
            ReleaseCommitWheel(
                options = PHOTO_COLUMN_OPTIONS,
                selected = columns,
                optionLabel = { it.toString() },
                onValueCommitted = onColumns,
                onDetent = haptics::tick,
                label = text.label(SettingsTextKey.columns),
                modifier = Modifier.weight(1f),
            )
            SharedBooleanSettingsWheel(
                text = text,
                label = text.label(SettingsTextKey.collapse_burst_photos),
                checked = collapseBursts,
                onCheckedChange = onCollapseBursts,
                hapticsEnabled = hapticsEnabled,
                modifier = Modifier.weight(1f),
            )
        }

        SharedCardDivider()

        val selectedPhotoInteraction = photoInteractionChoices.first {
            it.first == tapToPreview
        }
        ReleaseCommitWheel(
            options = photoInteractionChoices,
            selected = selectedPhotoInteraction,
            optionLabel = { (_, label) -> label },
            onValueCommitted = { (tapToPreview, _) ->
                onTapToPreview(tapToPreview)
            },
            onDetent = haptics::tick,
            label = text.label(SettingsTextKey.photo_interaction),
            optionRowHeight = 32.dp,
            optionMaxLines = 2,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

@kotlin.native.HiddenFromObjC
@Composable
fun SharedAppearanceSettingsCard(
    themeMode: ThemeMode, appLanguage: String, systemLanguageValue: String, skinPreset: SkinPreset,
    hapticsEnabled: Boolean, keepScreenOn: Boolean, text: SettingsControlsText,
    onTheme: (ThemeMode) -> Unit, onLanguage: (String) -> Unit, onSkin: (SkinPreset) -> Unit,
    onHaptics: (Boolean) -> Unit, onKeepScreenOn: (Boolean) -> Unit, close: () -> Unit,
) {
    val haptics = rememberHaptics(hapticsEnabled)
    // ---------- 明暗、语言、按钮材质：同款拨轮，全部只在松手后提交 ----------
    val themeChoices = ThemeMode.entries.map { mode ->
        mode to text.label(
            when (mode) {
                ThemeMode.SYSTEM -> SettingsTextKey.theme_system
                ThemeMode.DARK -> SettingsTextKey.theme_dark
                ThemeMode.LIGHT -> SettingsTextKey.theme_light
            }
        )
    }
    val selectedTheme = themeChoices.first { it.first == themeMode }
    val languages = listOf(
        systemLanguageValue to text.label(SettingsTextKey.language_system),
        "en" to "English",
        "zh-Hans" to "简体中文",
        "zh-Hant" to "繁體中文",
    )
    val selectedLanguage = languages.firstOrNull { it.first == appLanguage }
        ?: languages.first()
    val skinChoices = ButtonSkinDisplayOrder.map { skin ->
        skin to text.skinLabel(skin)
    }
    val selectedSkin = skinChoices.first { it.first == skinPreset }
    SharedSettingsCard {
        Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.fillMaxWidth(),
        ) {
            ReleaseCommitWheel(
                options = themeChoices,
                selected = selectedTheme,
                optionLabel = { it.second },
                onValueCommitted = { onTheme(it.first) },
                onDetent = haptics::tick,
                label = text.label(SettingsTextKey.light_dark_mode),
                wheelHeight = SettingsCompactWheelHeight,
                optionRowHeight = SettingsCompactWheelRowHeight,
                optionFontSize = SettingsCompactWheelFontSize,
                modifier = Modifier.weight(APPEARANCE_COMPACT_WHEEL_WEIGHT),
            )
            ReleaseCommitWheel(
                options = languages,
                selected = selectedLanguage,
                optionLabel = { it.second },
                onValueCommitted = { language ->
                    if (language.first != appLanguage) {
                        onLanguage(language.first)
                        close()
                    }
                },
                onDetent = haptics::tick,
                label = text.label(SettingsTextKey.language),
                wheelHeight = SettingsCompactWheelHeight,
                optionRowHeight = SettingsCompactWheelRowHeight,
                optionFontSize = SettingsCompactWheelFontSize,
                modifier = Modifier.weight(APPEARANCE_COMPACT_WHEEL_WEIGHT),
            )
            ReleaseCommitWheel(
                options = skinChoices,
                selected = selectedSkin,
                optionLabel = { it.second },
                onValueCommitted = { onSkin(it.first) },
                onDetent = haptics::tick,
                label = text.label(SettingsTextKey.button_style),
                wheelHeight = SettingsCompactWheelHeight,
                optionRowHeight = SettingsCompactWheelRowHeight,
                optionFontSize = SettingsCompactWheelFontSize,
                modifier = Modifier.weight(BUTTON_STYLE_WHEEL_WEIGHT),
            )
        }

        SharedCardDivider()

        Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.fillMaxWidth(),
        ) {
            SharedBooleanSettingsWheel(
                text = text,
                label = text.label(SettingsTextKey.haptic_feedback),
                checked = hapticsEnabled,
                onCheckedChange = onHaptics,
                hapticsEnabled = hapticsEnabled,
                isHapticsPreference = true,
                compact = true,
                modifier = Modifier.weight(1f),
            )
            SharedBooleanSettingsWheel(
                text = text,
                label = text.label(SettingsTextKey.keep_screen_on),
                checked = keepScreenOn,
                onCheckedChange = onKeepScreenOn,
                hapticsEnabled = hapticsEnabled,
                compact = true,
                modifier = Modifier.weight(1f),
            )
        }
    }
}
