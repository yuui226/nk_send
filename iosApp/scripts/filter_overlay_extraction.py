"""Full original filter/date UI extraction. Calendar, text, width and system back are slots.

Android keeps its java.time helpers and passes the same resource/configuration/back APIs.
Every geometry, animation, draft and commit expression is compared to 55876fa.
"""
import re
from thumbnail_grid_extraction import HEADER, section
from transfer_card_extraction import replace_once

KEYS = ['filter_other', 'filter_title', 'filter_section_file_type', 'filter_all',
    'filter_section_status', 'filter_protected', 'burst_label', 'filter_untransferred',
    'filter_section_storage', 'filter_storage_slot', 'filter_section_date', 'filter_date',
    'clear', 'cd_back', 'date_range', 'date_start', 'date_end', 'done', 'date_year', 'date_month', 'date_day']


def extract_anchor_popup(source):
    source = source.replace('\r\n', '\n')
    shared = replace_once(source, 'import androidx.activity.compose.BackHandler\n', '')
    shared = replace_once(shared, 'fun AnchorPopup(', 'fun SharedAnchorPopup(')
    shared = replace_once(shared, '    anchorBounds: Rect?,',
        '    anchorBounds: Rect?,\n    backHandler: @Composable (() -> Unit) -> Unit = {},')
    shared = replace_once(shared, '    BackHandler { startClose() }', '    backHandler { startClose() }')
    signature = section(source, '@Composable\nfun AnchorPopup(', '    val colors = AppTheme.colors')
    wrapper = source[:source.index('/** 布局/开合')] + signature + '''    SharedAnchorPopup(
        anchorBounds = anchorBounds, onDismiss = onDismiss, panelModifier = panelModifier,
        panelAlignment = panelAlignment, animateScale = animateScale, shape = shape, dim = dim,
        overlayContent = overlayContent, content = content,
        backHandler = { close -> BackHandler(onBack = close) },
    )
}
'''
    shared = '@file:OptIn(kotlin.experimental.ExperimentalObjCRefinement::class)\n\n' + shared
    shared = replace_once(shared, '@Composable\nfun SharedAnchorPopup(', '@kotlin.native.HiddenFromObjC\n@Composable\nfun SharedAnchorPopup(')
    return wrapper, shared


def extract_filter_overlay(source):
    source = source.replace('\r\n', '\n')
    android = source
    body = section(source, '@Composable\nprivate fun FilterOverlay(', 'private fun LocalDate.withClampedDate(')
    helpers = section(source, 'private fun LocalDate.withClampedDate(', '/**\n * 筛选面板的选中态胶囊')
    chips = section(source, '/**\n * 筛选面板的选中态胶囊', '/** 合集数量角标：')
    shared = body.replace('PhotoFilterCriteria', 'SharedPhotoFilterCriteria<R>').replace('PhotoDateRange?', 'R?').replace('LocalDate?', 'D?')
    shared = shared.replace('private fun FilterOverlay(', 'fun <D : Any, R : Any> SharedFilterOverlay(')
    shared = replace_once(shared, '    anchorBounds: Rect,', '''    anchorBounds: Rect,
    untransferredEnabled: Boolean = true,
    calendar: FilterCalendar<D, R>,
    text: FilterOverlayText,
    screenWidth: Dp,
    backHandler: @Composable (() -> Unit) -> Unit = {},''')
    shared = replace_once(shared, '    val screenWidth = LocalConfiguration.current.screenWidthDp.dp\n', '')
    shared = replace_once(shared, '    AnchorPopup(', '    SharedAnchorPopup(\n        backHandler = backHandler,')
    shared = replace_once(shared, '                DateRangeEditor(', '                DateRangeEditor(\n                    calendar = calendar, text = text,')
    shared = replace_once(shared, '                            FilterClearButton(', '                            FilterClearButton(\n                                text = text,')
    shared = replace_once(shared, 'private fun FilterClearButton(onClick: () -> Unit)', 'private fun FilterClearButton(text: FilterOverlayText, onClick: () -> Unit)')
    shared = replace_once(shared, 'compactDateRangeLabel(working.dateRange)', 'calendar.compactRange(working.dateRange)')
    for name in ('DateRangeEditor', 'DateEndpointWheels'):
        shared = replace_once(shared, 'private fun '+name+'(',
            'private fun <D : Any, R : Any> '+name+'(\n    calendar: FilterCalendar<D, R>,\n    text: FilterOverlayText,')
    shared = shared.replace('onDateChanged: (LocalDate)', 'onDateChanged: (D)').replace('date: LocalDate,', 'date: D,')
    shared = shared.replace('fun updateStart(next: LocalDate)', 'fun updateStart(next: D)').replace('fun updateEnd(next: LocalDate)', 'fun updateEnd(next: D)')
    # Calendar is a receiver only within these two date UI functions. Android calls the old Java helpers.
    for start, end in [('@Composable\nprivate fun <D : Any, R : Any> DateRangeEditor(', '@Composable\nprivate fun <D : Any, R : Any> DateEndpointWheels('),
                       ('@Composable\nprivate fun <D : Any, R : Any> DateEndpointWheels(', None)]:
        block = shared[shared.index(start):] if end is None else section(shared, start, end)
        converted = replace_once(block, ') {\n    val colors', ') = with(calendar) {\n    val colors')
        converted = converted.replace('LocalDate.now()', 'today()').replace('PhotoDateRange.between(', 'between(')
        converted = converted.replace('YearMonth.of(date.year, date.monthValue).lengthOfMonth()', 'monthLength(date.year, date.monthValue)')
        converted = converted.replace('formatLocalDate(date)', 'formatDate(date)')
        converted = converted.replace('        DateEndpointWheels(', '        DateEndpointWheels(\n            calendar = calendar, text = text,')
        shared = replace_once(shared, block, converted)
    for key in KEYS:
        shared = shared.replace('stringResource(R.string.'+key+', slot)', 'text.label(FilterTextKey.'+key+', slot)')
        shared = shared.replace('stringResource(R.string.'+key+')', 'text.label(FilterTextKey.'+key+')')
    shared += chips.replace('internal fun FilterChip(', 'fun FilterChip(')
    shared = replace_once(shared, '                            selected = working.untransferredOnly,',
        '                            selected = working.untransferredOnly,\n                            enabled = untransferredEnabled,')
    shared = replace_once(shared, '    leading: (@Composable (Color) -> Unit)? = null\n',
        '    leading: (@Composable (Color) -> Unit)? = null,\n    enabled: Boolean = true,\n')
    shared = replace_once(shared, '        modifier = modifier.height(38.dp)\n',
        '        modifier = modifier.height(38.dp),\n        enabled = enabled,\n')
    constants = ''
    for name in ('FILTER_PANEL_MAX_WIDTH', 'FILTER_PANEL_SCREEN_MARGIN', 'DATE_FILTER_WHEEL_HEIGHT'):
        line = next(x for x in source.splitlines(True) if x.startswith('private val '+name+' ='))
        android = replace_once(android, line, '')
        constants += line
    # Preserve Android's public criteria, LocalDate, callbacks and all existing callers.
    signature = body[:body.index('    val colors = AppTheme.colors')]
    wrapper = signature + '''    SharedFilterOverlay(
        anchorBounds = anchorBounds, availableExts = availableExts, storageSlots = storageSlots,
        current = SharedPhotoFilterCriteria(current.extensions, current.protectedOnly, current.burstOnly,
            current.untransferredOnly, current.storageSlot, current.dateRange),
        suggestedDate = suggestedDate, hapticsEnabled = hapticsEnabled,
        calendar = AndroidFilterCalendar, text = AndroidFilterOverlayText,
        screenWidth = LocalConfiguration.current.screenWidthDp.dp,
        backHandler = { close -> androidx.activity.compose.BackHandler(onBack = close) },
        onChange = { next -> onChange(PhotoFilterCriteria(next.extensions, next.protectedOnly,
            next.burstOnly, next.untransferredOnly, next.storageSlot, next.dateRange)) },
        onDismiss = onDismiss,
    )
}

internal object AndroidFilterCalendar : FilterCalendar<LocalDate, PhotoDateRange> {
    override fun today(): LocalDate = LocalDate.now()
    override val LocalDate.year: Int get() = getYear()
    override val LocalDate.monthValue: Int get() = getMonthValue()
    override val LocalDate.dayOfMonth: Int get() = getDayOfMonth()
    override val PhotoDateRange.start: LocalDate get() = this.start
    override val PhotoDateRange.endInclusive: LocalDate get() = this.endInclusive
    override fun LocalDate.isAfter(other: LocalDate): Boolean = this.isAfter(other)
    override fun LocalDate.isBefore(other: LocalDate): Boolean = this.isBefore(other)
    override fun LocalDate.withClampedDate(year: Int, month: Int, day: Int): LocalDate =
        this.androidClampedDate(year, month, day)
    override fun monthLength(year: Int, month: Int): Int = YearMonth.of(year, month).lengthOfMonth()
    override fun between(first: LocalDate, second: LocalDate): PhotoDateRange = PhotoDateRange.between(first, second)
    override fun formatDate(date: LocalDate): String = formatLocalDate(date)
    override fun compactRange(range: PhotoDateRange?): String? = compactDateRangeLabel(range)
}

private object AndroidFilterOverlayText : FilterOverlayText {
    @Composable override fun label(key: FilterTextKey, slot: Int): String = when (key) {
'''
    for key in KEYS:
        wrapper += '        FilterTextKey.'+key+' -> stringResource(R.string.'+key+(', slot' if key == 'filter_storage_slot' else '')+')\n'
    wrapper += '    }\n}\n\n'
    android = replace_once(android, body, wrapper)
    android = replace_once(android, chips, '')
    android = replace_once(android, 'private fun LocalDate.withClampedDate(', 'private fun LocalDate.androidClampedDate(')
    extra = '''import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.vector.ImageVector
import com.ztransfer.catalog.isStorageSlotSelected
import com.ztransfer.catalog.toggleStorageSlotSelection
import com.ztransfer.ui.util.rememberHaptics

'''
    shared = shared.replace('@Composable\nfun <D : Any, R : Any> SharedFilterOverlay(', '@kotlin.native.HiddenFromObjC\n@Composable\nfun <D : Any, R : Any> SharedFilterOverlay(')
    shared = shared.replace('@Composable\nfun FilterChip(', '@kotlin.native.HiddenFromObjC\n@Composable\nfun FilterChip(')
    return android, HEADER + extra + constants + '\n' + shared.rstrip('\n') + '\n'


def expected_contract():
    return '''@file:OptIn(kotlin.experimental.ExperimentalObjCRefinement::class)

package com.ztransfer.ui.screen

import androidx.compose.runtime.Composable

/** UI value only. Platform persistence and actual file filtering remain outside this component. */
@kotlin.native.HiddenFromObjC
data class SharedPhotoFilterCriteria<R>(
    val extensions: Set<String>? = null,
    val protectedOnly: Boolean = false,
    val burstOnly: Boolean = false,
    val untransferredOnly: Boolean = false,
    val storageSlot: Int? = null,
    val dateRange: R? = null,
)

/** Calendar operations only; Android retains its original LocalDate/PhotoDateRange implementations. */
@kotlin.native.HiddenFromObjC
interface FilterCalendar<D : Any, R : Any> {
    fun today(): D
    val D.year: Int
    val D.monthValue: Int
    val D.dayOfMonth: Int
    val R.start: D
    val R.endInclusive: D
    fun D.isAfter(other: D): Boolean
    fun D.isBefore(other: D): Boolean
    fun D.withClampedDate(year: Int = this.year, month: Int = this.monthValue, day: Int = this.dayOfMonth): D
    fun monthLength(year: Int, month: Int): Int
    fun between(first: D, second: D): R
    fun formatDate(date: D): String
    fun compactRange(range: R?): String?
}

@kotlin.native.HiddenFromObjC
enum class FilterTextKey { ''' + ', '.join(KEYS) + ''' }
@kotlin.native.HiddenFromObjC
interface FilterOverlayText {
    @Composable fun label(key: FilterTextKey, slot: Int = 0): String
}
'''
