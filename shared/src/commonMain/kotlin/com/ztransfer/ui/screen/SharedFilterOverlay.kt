@file:OptIn(kotlin.experimental.ExperimentalObjCRefinement::class)

package com.ztransfer.ui.screen

import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.*
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.*
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.*
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.*
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.*
import com.ztransfer.protocol.CameraFileInfo
import com.ztransfer.ui.theme.*
import com.ztransfer.viewmodel.ActiveTransferProgress
import com.ztransfer.viewmodel.TransferStatus
import com.ztransfer.viewmodel.TransferTask
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.vector.ImageVector
import com.ztransfer.catalog.isStorageSlotSelected
import com.ztransfer.catalog.toggleStorageSlotSelection
import com.ztransfer.ui.util.rememberHaptics

private val FILTER_PANEL_MAX_WIDTH = 360.dp
private val FILTER_PANEL_SCREEN_MARGIN = 12.dp
private val DATE_FILTER_WHEEL_HEIGHT = 50.dp

@kotlin.native.HiddenFromObjC
@Composable
fun <D : Any, R : Any> SharedFilterOverlay(
    anchorBounds: Rect,
    untransferredEnabled: Boolean = true,
    calendar: FilterCalendar<D, R>,
    text: FilterOverlayText,
    screenWidth: Dp,
    backHandler: @Composable (() -> Unit) -> Unit = {},
    availableExts: List<String>,
    current: SharedPhotoFilterCriteria<R>,
    storageSlots: List<Int>,
    suggestedDate: D?,
    hapticsEnabled: Boolean,
    onChange: (SharedPhotoFilterCriteria<R>) -> Unit,
    onDismiss: () -> Unit
) {
    val colors = AppTheme.colors
    val density = LocalDensity.current
    var editingDate by remember { mutableStateOf(false) }
    val panelWidth = minOf(
        FILTER_PANEL_MAX_WIDTH,
        screenWidth - FILTER_PANEL_SCREEN_MARGIN * 2,
    )
    // 顶边贴按钮下缘 + 8dp；左缘对齐按钮，但不许超出屏幕右缘（信号条展开把按钮推得很靠右/
    // 窄屏时，面板整体向左钳制到贴边 12dp）。
    val panelTop = with(density) { anchorBounds.bottom.toDp() } + 8.dp
    val panelStart = with(density) { anchorBounds.left.toDp() }
        .coerceAtMost(screenWidth - panelWidth - FILTER_PANEL_SCREEN_MARGIN)
        .coerceAtLeast(FILTER_PANEL_SCREEN_MARGIN)

    // 外部“一键清除”发生时同步丢弃面板草稿，不能让旧日期范围继续存活。
    var working by remember(current) { mutableStateOf(current) }

    val otherLabel = text.label(FilterTextKey.filter_other)
    fun extLabel(ext: String) = ext.removePrefix(".").uppercase().ifEmpty { otherLabel }
    fun commit(next: SharedPhotoFilterCriteria<R>) {
        if (next == working) return
        working = next
        onChange(next)
    }
    fun toggle(ext: String) {
        val cur = working.extensions ?: availableExts.toSet()
        val next = if (ext in cur) cur - ext else cur + ext
        val normalized = when {
            next.isEmpty() -> null                       // 全不选无意义，归位"全部"
            next.containsAll(availableExts) -> null      // 凑齐全部现有类型 = 全部
            else -> next
        }
        commit(working.copy(extensions = normalized))
    }

    SharedAnchorPopup(
        backHandler = backHandler,
        anchorBounds = anchorBounds,
        onDismiss = onDismiss,
        panelModifier = Modifier
            .padding(start = panelStart, top = panelTop)
            .width(panelWidth),
        animateScale = false,
        genieFromAnchor = true,
        shape = RoundedCornerShape(16.dp),
        dim = false,
    ) { _ ->
        AnimatedContent(
            targetState = editingDate,
            transitionSpec = {
                fadeIn(tween(150)) togetherWith fadeOut(tween(100)) using SizeTransform(clip = false)
            },
            label = "filterDateEditor",
        ) { showDateEditor ->
            if (showDateEditor) {
                DateRangeEditor(
                    calendar = calendar, text = text,
                    current = working.dateRange,
                    suggestedDate = suggestedDate,
                    hapticsEnabled = hapticsEnabled,
                    onBack = { editingDate = false },
                    onApply = { range ->
                        commit(working.copy(dateRange = range))
                        editingDate = false
                    },
                )
            } else {
                Column(
                    modifier = Modifier.padding(14.dp),
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        FilterMark(
                            modifier = Modifier.size(18.dp),
                            color = colors.accentBlue,
                        )
                        Text(
                            text = text.label(FilterTextKey.filter_title),
                            style = MaterialTheme.typography.titleSmall,
                            fontWeight = FontWeight.SemiBold,
                            color = colors.onBackground,
                        )
                    }

                    Spacer(Modifier.height(14.dp))

                    FilterSectionLabel(
                        label = text.label(FilterTextKey.filter_section_file_type),
                    )
                    Spacer(Modifier.height(8.dp))

                    // ---- 类型：全部 + 各扩展名，短标签最多五列，保持原有多选语义 ----
                    val typeChips: List<Triple<String, Boolean, () -> Unit>> = buildList {
                        add(Triple(text.label(FilterTextKey.filter_all), working.extensions == null) {
                            if (working.extensions != null) {
                                commit(working.copy(extensions = null))
                            }
                        })
                        availableExts.forEach { ext ->
                            add(Triple(extLabel(ext), working.extensions?.contains(ext) ?: true) { toggle(ext) })
                        }
                    }
                    val typeColumnCount = minOf(5, typeChips.size.coerceAtLeast(1))
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        typeChips.chunked(typeColumnCount).forEach { rowChips ->
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                rowChips.forEach { (label, selected, onClick) ->
                                    FilterChip(label, selected, onClick, Modifier.weight(1f))
                                }
                                repeat(typeColumnCount - rowChips.size) {
                                    Spacer(Modifier.weight(1f))
                                }
                            }
                        }
                    }

                    FilterSectionDivider()

                    FilterSectionLabel(
                        label = text.label(FilterTextKey.filter_section_status),
                    )
                    Spacer(Modifier.height(8.dp))

                    // ---- 标记：保护 / 连拍 / 未传输（独立开关，与日期和类型叠加）----
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        FilterChip(
                            label = text.label(FilterTextKey.filter_protected),
                            selected = working.protectedOnly,
                            onClick = {
                                commit(working.copy(protectedOnly = !working.protectedOnly))
                            },
                            modifier = Modifier.weight(1f),
                            icon = Icons.Default.Key
                        )
                        FilterChip(
                            label = text.label(FilterTextKey.burst_label),
                            selected = working.burstOnly,
                            onClick = {
                                commit(working.copy(burstOnly = !working.burstOnly))
                            },
                            modifier = Modifier.weight(1f),
                            leading = { tint -> BurstGlyph(tint = tint) }
                        )
                        FilterChip(
                            label = text.label(FilterTextKey.filter_untransferred),
                            selected = working.untransferredOnly,
                            enabled = untransferredEnabled,
                            onClick = {
                                commit(working.copy(untransferredOnly = !working.untransferredOnly))
                            },
                            modifier = Modifier.weight(1f),
                            leading = { tint -> UntransferredGlyph(tint = tint) },
                        )
                    }

                    if (storageSlots.isNotEmpty()) {
                        FilterSectionDivider()

                        FilterSectionLabel(
                            label = text.label(FilterTextKey.filter_section_storage),
                        )
                        Spacer(Modifier.height(8.dp))

                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            storageSlots.forEach { slot ->
                                FilterChip(
                                    label = text.label(FilterTextKey.filter_storage_slot, slot),
                                    selected = isStorageSlotSelected(working.storageSlot, slot),
                                    onClick = {
                                        commit(
                                            working.copy(
                                                storageSlot = toggleStorageSlotSelection(
                                                    selectedSlot = working.storageSlot,
                                                    toggledSlot = slot,
                                                    availableSlots = storageSlots,
                                                )
                                            )
                                        )
                                    },
                                    modifier = Modifier.weight(1f),
                                )
                            }
                            if (storageSlots.size == 1) Spacer(Modifier.weight(1f))
                        }
                    }

                    FilterSectionDivider()

                    FilterSectionLabel(
                        label = text.label(FilterTextKey.filter_section_date),
                    )
                    Spacer(Modifier.height(8.dp))

                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        FilterChip(
                            label = calendar.compactRange(working.dateRange)
                                ?: text.label(FilterTextKey.filter_date),
                            selected = working.dateRange != null,
                            onClick = { editingDate = true },
                            modifier = Modifier.weight(1f),
                            icon = Icons.Default.DateRange,
                        )
                        if (working.dateRange != null) {
                            FilterClearButton(
                                text = text,
                                onClick = { commit(working.copy(dateRange = null)) },
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun FilterSectionLabel(
    label: String,
) {
    val colors = AppTheme.colors
    Text(
        text = label,
        style = MaterialTheme.typography.labelMedium,
        fontWeight = FontWeight.SemiBold,
        color = colors.onSurfaceVariant,
    )
}

@Composable
private fun FilterSectionDivider() {
    val colors = AppTheme.colors
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 13.dp, horizontal = 2.dp)
            .height(1.dp)
            .background(colors.glassPanelBorder),
    )
}

@Composable
private fun FilterClearButton(text: FilterOverlayText, onClick: () -> Unit) {
    val colors = AppTheme.colors
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(9.dp),
        color = colors.surfaceVariant,
        modifier = Modifier.size(38.dp),
    ) {
        Box(contentAlignment = Alignment.Center) {
            Icon(
                imageVector = Icons.Default.Close,
                contentDescription = text.label(FilterTextKey.clear),
                tint = colors.onSurfaceVariant,
                modifier = Modifier.size(16.dp),
            )
        }
    }
}

@Composable
private fun <D : Any, R : Any> DateRangeEditor(
    calendar: FilterCalendar<D, R>,
    text: FilterOverlayText,
    current: R?,
    suggestedDate: D?,
    hapticsEnabled: Boolean,
    onBack: () -> Unit,
    onApply: (R?) -> Unit,
) = with(calendar) {
    val colors = AppTheme.colors
    val haptics = rememberHaptics(hapticsEnabled)
    val initial = current?.endInclusive ?: suggestedDate ?: today()
    // 编辑页进入时快照一次；文件列表仍在渐进加载时 suggestedDate 可能变化，不能把用户
    // 已经拨到一半的草稿重置掉。
    var start by remember { mutableStateOf(current?.start ?: initial) }
    var end by remember { mutableStateOf(current?.endInclusive ?: initial) }

    fun updateStart(next: D) {
        start = next
        if (next.isAfter(end)) end = next
    }

    fun updateEnd(next: D) {
        end = next
        if (next.isBefore(start)) start = next
    }

    val minYear = minOf(1990, start.year, end.year)
    val maxYear = maxOf(today().year + 1, start.year, end.year)
    val years = remember(minYear, maxYear) { (minYear..maxYear).toList() }

    Column(
        modifier = Modifier.padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack, modifier = Modifier.size(34.dp)) {
                Icon(
                    Icons.Default.ArrowBack,
                    contentDescription = text.label(FilterTextKey.cd_back),
                    tint = colors.onBackground,
                    modifier = Modifier.size(18.dp),
                )
            }
            Spacer(Modifier.width(4.dp))
            Text(
                text.label(FilterTextKey.date_range),
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.SemiBold,
                color = colors.onBackground,
            )
        }

        DateEndpointWheels(
            calendar = calendar, text = text,
            label = text.label(FilterTextKey.date_start),
            date = start,
            years = years,
            onDateChanged = ::updateStart,
            onDetent = haptics::tick,
        )

        DateEndpointWheels(
            calendar = calendar, text = text,
            label = text.label(FilterTextKey.date_end),
            date = end,
            years = years,
            onDateChanged = ::updateEnd,
            onDetent = haptics::tick,
        )

        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            GlassButton(
                onClick = { onApply(null) },
                modifier = Modifier.weight(1f).height(40.dp),
                shape = RoundedCornerShape(11.dp),
                panel = true,
            ) {
                Text(text.label(FilterTextKey.clear), color = colors.onSurfaceVariant)
            }
            GlassButton(
                onClick = { onApply(between(start, end)) },
                modifier = Modifier.weight(1f).height(40.dp),
                shape = RoundedCornerShape(11.dp),
                active = true,
                activeColor = colors.accentBlue,
            ) {
                Text(
                    text.label(FilterTextKey.done),
                    color = colors.onBackground,
                    fontWeight = FontWeight.SemiBold,
                )
            }
        }
    }
}

@Composable
private fun <D : Any, R : Any> DateEndpointWheels(
    calendar: FilterCalendar<D, R>,
    text: FilterOverlayText,
    label: String,
    date: D,
    years: List<Int>,
    onDateChanged: (D) -> Unit,
    onDetent: () -> Unit,
) = with(calendar) {
    val colors = AppTheme.colors
    val months = remember { (1..12).toList() }
    val days = remember(date.year, date.monthValue) {
        (1..monthLength(date.year, date.monthValue)).toList()
    }
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text(
                label,
                style = MaterialTheme.typography.labelMedium,
                fontWeight = FontWeight.SemiBold,
                color = colors.onBackground,
            )
            Spacer(Modifier.weight(1f))
            Text(
                formatDate(date),
                style = MaterialTheme.typography.labelSmall,
                color = colors.onSurfaceVariant,
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            ReleaseCommitWheel(
                options = years,
                selected = date.year,
                optionLabel = Int::toString,
                onValueCommitted = { onDateChanged(date.withClampedDate(year = it)) },
                onDetent = onDetent,
                label = text.label(FilterTextKey.date_year),
                wheelHeight = DATE_FILTER_WHEEL_HEIGHT,
                modifier = Modifier.weight(1.3f),
            )
            ReleaseCommitWheel(
                options = months,
                selected = date.monthValue,
                optionLabel = { it.toString().padStart(2, '0') },
                onValueCommitted = { onDateChanged(date.withClampedDate(month = it)) },
                onDetent = onDetent,
                label = text.label(FilterTextKey.date_month),
                wheelHeight = DATE_FILTER_WHEEL_HEIGHT,
                modifier = Modifier.weight(1f),
            )
            ReleaseCommitWheel(
                options = days,
                selected = date.dayOfMonth,
                optionLabel = { it.toString().padStart(2, '0') },
                onValueCommitted = { onDateChanged(date.withClampedDate(day = it)) },
                onDetent = onDetent,
                label = text.label(FilterTextKey.date_day),
                wheelHeight = DATE_FILTER_WHEEL_HEIGHT,
                modifier = Modifier.weight(1f),
            )
        }
    }
}

/**
 * 筛选面板的选中态胶囊：选中 = 主题蓝底 + 反色加粗字；未选 = surfaceVariant 底。
 * 与设置面板的选择胶囊同族语言。
 */
@kotlin.native.HiddenFromObjC
@Composable
fun FilterChip(
    label: String? = null,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    icon: ImageVector? = null,
    // 自定义前导内容（如连拍的 BurstGlyph）；给定内容色，优先于 [icon]。
    leading: (@Composable (Color) -> Unit)? = null,
    enabled: Boolean = true,
) {
    val colors = AppTheme.colors
    val contentColor = if (selected) colors.onAccent else colors.onSurfaceVariant
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(9.dp),
        color = if (selected) colors.accentBlue else colors.surfaceVariant,
        modifier = modifier.height(38.dp),
        enabled = enabled,
    ) {
        Row(
            modifier = Modifier
                .fillMaxSize()
                .padding(horizontal = 6.dp),
            horizontalArrangement = Arrangement.spacedBy(5.dp, Alignment.CenterHorizontally),
            verticalAlignment = Alignment.CenterVertically
        ) {
            when {
                leading != null -> leading(contentColor)
                icon != null -> Icon(icon, contentDescription = null, tint = contentColor, modifier = Modifier.size(14.dp))
            }
            if (label != null) {
                Text(
                    label,
                    style = MaterialTheme.typography.labelLarge,
                    fontWeight = if (selected) FontWeight.Bold else FontWeight.Medium,
                    maxLines = 1,
                    color = contentColor
                )
            }
        }
    }
}

/** “未传”标志：向下箭头落入接收槽，表达照片仍等待传入手机。 */
@Composable
private fun UntransferredGlyph(
    tint: Color,
    modifier: Modifier = Modifier,
    iconSize: Dp = 14.dp,
) {
    Canvas(modifier = modifier.size(iconSize)) {
        val stroke = size.minDimension * 0.11f
        val centerX = size.width * 0.5f
        val arrowTipY = size.height * 0.58f
        drawLine(
            color = tint,
            start = Offset(centerX, size.height * 0.12f),
            end = Offset(centerX, arrowTipY),
            strokeWidth = stroke,
            cap = StrokeCap.Round,
        )
        drawLine(
            color = tint,
            start = Offset(size.width * 0.31f, size.height * 0.40f),
            end = Offset(centerX, arrowTipY),
            strokeWidth = stroke,
            cap = StrokeCap.Round,
        )
        drawLine(
            color = tint,
            start = Offset(size.width * 0.69f, size.height * 0.40f),
            end = Offset(centerX, arrowTipY),
            strokeWidth = stroke,
            cap = StrokeCap.Round,
        )
        drawLine(
            color = tint,
            start = Offset(size.width * 0.18f, size.height * 0.67f),
            end = Offset(size.width * 0.18f, size.height * 0.84f),
            strokeWidth = stroke,
            cap = StrokeCap.Round,
        )
        drawLine(
            color = tint,
            start = Offset(size.width * 0.18f, size.height * 0.84f),
            end = Offset(size.width * 0.82f, size.height * 0.84f),
            strokeWidth = stroke,
            cap = StrokeCap.Round,
        )
        drawLine(
            color = tint,
            start = Offset(size.width * 0.82f, size.height * 0.84f),
            end = Offset(size.width * 0.82f, size.height * 0.67f),
            strokeWidth = stroke,
            cap = StrokeCap.Round,
        )
    }
}
