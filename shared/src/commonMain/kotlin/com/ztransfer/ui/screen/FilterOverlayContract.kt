@file:OptIn(kotlin.experimental.ExperimentalObjCRefinement::class)

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
enum class FilterTextKey { filter_other, filter_title, filter_section_file_type, filter_all, filter_section_status, filter_protected, burst_label, filter_untransferred, filter_section_storage, filter_storage_slot, filter_section_date, filter_date, clear, cd_back, date_range, date_start, date_end, done, date_year, date_month, date_day }
@kotlin.native.HiddenFromObjC
interface FilterOverlayText {
    @Composable fun label(key: FilterTextKey, slot: Int = 0): String
}
