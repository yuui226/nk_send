package com.ztransfer.viewmodel

import com.ztransfer.effects.FavoritePhotoFilter
import com.ztransfer.filter.BuiltInPhotoFilters
import com.ztransfer.filter.DEFAULT_PHOTO_FILTER_INTENSITY_PERCENT
import com.ztransfer.filter.LutAdjustments
import com.ztransfer.filter.PhotoFilterSelection
import com.ztransfer.filter.photoFilterCatalogKey
import com.ztransfer.protocol.NikonCamera
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test

class PhotoPresetDirectoryStateTest {
    private val builtIn = BuiltInPhotoFilters.all.first()
    private val builtInKey = checkNotNull(photoFilterCatalogKey(builtIn.id))
    private val customKey = "np3:${"a".repeat(64)}"
    private val custom = builtIn.copy(id = "$customKey:np3-srgb-v1", name = "External")
    private val controls = LutAdjustments(20, -10, 15, -25)

    @Test fun replacementClearsExternalControlsButLeavesQueuedRecipeAndRegistryOwnersIntact() {
        val queuedRecipe = PhotoFilterSelection(custom, 42, controls)
        val tasks = listOf(TransferTask(
            NikonCamera.FileInfo(1, 100L, "DSC_1.JPG", captureDate = null),
            photoFilterRequested = queuedRecipe,
        ))
        val state = TransferState(
            tasks = tasks,
            photoFilters = listOf(builtIn, custom),
            selectedPhotoFilterId = custom.id,
            photoFilterEnabled = true,
            photoFilterIntensityPercent = 42,
            photoFilterAdjustments = controls,
            transferPhotoFilterIntensities = mapOf(builtInKey to 64, customKey to 42),
            transferPhotoFilterAdjustments = mapOf(builtInKey to LutAdjustments(-5), customKey to controls),
            favoritePhotoFilters = listOf(FavoritePhotoFilter(customKey), FavoritePhotoFilter(builtInKey)),
        )
        val cleared = clearTransferPhotoNp3DirectorySettings(state)
        assertNull(cleared.selectedPhotoFilterId)
        assertFalse(cleared.photoFilterEnabled)
        assertNull(cleared.photoFilterSelection)
        assertEquals(DEFAULT_PHOTO_FILTER_INTENSITY_PERCENT, cleared.photoFilterIntensityPercent)
        assertEquals(LutAdjustments(), cleared.photoFilterAdjustments)
        assertEquals(listOf(builtIn), cleared.photoFilters)
        assertEquals(mapOf(builtInKey to 64), cleared.transferPhotoFilterIntensities)
        assertEquals(mapOf(builtInKey to LutAdjustments(-5)), cleared.transferPhotoFilterAdjustments)
        assertEquals(listOf(FavoritePhotoFilter(builtInKey)), cleared.favoritePhotoFilters)
        assertSame(tasks, cleared.tasks)
        assertSame(queuedRecipe, cleared.tasks.single().photoFilterRequested)
        assertSame(custom, cleared.tasks.single().photoFilterRequested!!.preset)
        assertEquals(controls, cleared.tasks.single().photoFilterRequested!!.lutAdjustments)
    }

    @Test fun replacementPreservesActiveBuiltInAndOtherEffectsWhileClearingUnusedCustomHistory() {
        val state = TransferState(
            photoFilters = listOf(builtIn, custom), selectedPhotoFilterId = builtIn.id,
            photoFilterEnabled = true, photoFilterIntensityPercent = 64, photoFilterAdjustments = controls,
            transferPhotoFilterIntensities = mapOf(builtInKey to 64, customKey to 22),
            transferPhotoFilterAdjustments = mapOf(builtInKey to controls, customKey to LutAdjustments(10)),
            favoritePhotoFilters = listOf(FavoritePhotoFilter(builtInKey), FavoritePhotoFilter(customKey)),
        )
        val expected = state.copy(
            photoFilters = listOf(builtIn), transferPhotoFilterIntensities = mapOf(builtInKey to 64),
            transferPhotoFilterAdjustments = mapOf(builtInKey to controls),
            favoritePhotoFilters = listOf(FavoritePhotoFilter(builtInKey)),
        )
        assertEquals(expected, clearTransferPhotoNp3DirectorySettings(state))
        assertEquals(state.photoFilterSelection, clearTransferPhotoNp3DirectorySettings(state).photoFilterSelection)
    }
}
