package com.ztransfer.viewmodel

import com.ztransfer.filter.DEFAULT_PHOTO_FILTER_INTENSITY_PERCENT
import com.ztransfer.filter.LutAdjustments
import com.ztransfer.filter.isCustomPhotoFilterCatalogKey
import com.ztransfer.filter.photoFilterCatalogKey

/** Queued recipes own their preset snapshots; changing the source directory only resets controls. */
internal fun clearTransferPhotoNp3DirectorySettings(state: TransferState): TransferState {
    fun custom(id: String?) = isCustomPhotoFilterCatalogKey(id?.let(::photoFilterCatalogKey).orEmpty())
    val selectedCustom = custom(state.selectedPhotoFilterId)
    return state.copy(
        photoFilters = state.photoFilters.filterNot { custom(it.id) },
        selectedPhotoFilterId = state.selectedPhotoFilterId.takeUnless { selectedCustom },
        photoFilterEnabled = state.photoFilterEnabled && !selectedCustom,
        photoFilterIntensityPercent = if (selectedCustom) DEFAULT_PHOTO_FILTER_INTENSITY_PERCENT
            else state.photoFilterIntensityPercent,
        photoFilterAdjustments = if (selectedCustom) LutAdjustments() else state.photoFilterAdjustments,
        transferPhotoFilterIntensities = state.transferPhotoFilterIntensities
            .filterKeys { !isCustomPhotoFilterCatalogKey(it) },
        transferPhotoFilterAdjustments = state.transferPhotoFilterAdjustments
            .filterKeys { !isCustomPhotoFilterCatalogKey(it) },
        favoritePhotoFilters = state.favoritePhotoFilters.filterNot { isCustomPhotoFilterCatalogKey(it.catalogKey) },
    )
}
