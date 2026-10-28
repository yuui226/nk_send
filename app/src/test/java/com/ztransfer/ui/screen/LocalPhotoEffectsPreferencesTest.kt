package com.ztransfer.ui.screen

import com.ztransfer.grain.PhotoGrainSettings
import com.ztransfer.grain.PhotoGrainStyle
import com.ztransfer.effects.ALL_PHOTO_EFFECT_MODULES
import com.ztransfer.effects.PhotoEffectModule
import com.ztransfer.effects.photoFilterAdjustmentsFor
import com.ztransfer.filter.LutAdjustments
import com.ztransfer.filter.BuiltInPhotoFilters
import com.ztransfer.filter.DEFAULT_PHOTO_FILTER_INTENSITY_PERCENT
import com.ztransfer.filter.photoFilterCatalogKey
import com.ztransfer.frame.PhotoFramePreset
import com.ztransfer.frame.defaultPhotoFrameMetadataSettings
import com.ztransfer.frame.PhotoFrameWatermark
import com.ztransfer.frame.PhotoFrameWatermarkContent
import com.ztransfer.frame.PhotoFrameWatermarkFont
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

class LocalPhotoEffectsPreferencesTest {
    @Test fun directoryReplacementForgetsExternalControlsAndSelectionWithoutChangingOtherEffects() {
        val builtIn = BuiltInPhotoFilters.all.first()
        val builtInKey = checkNotNull(photoFilterCatalogKey(builtIn.id))
        val customKey = "np3:${"a".repeat(64)}"
        val customId = "$customKey:np3-srgb-v1"
        val settings = defaultLocalPhotoEffectsSettings(customId).copy(
            decorationEnabled = true,
            filterEnabled = true,
            filterIntensityPercent = 42,
            filterIntensities = mapOf(customKey to 42, builtInKey to 64),
            filterAdjustments = mapOf(customKey to LutAdjustments(20), builtInKey to LutAdjustments(-15)),
        )
        val cleared = clearLocalPhotoNp3DirectorySettings(settings)
        assertEquals(settings.copy(
            filterId = null,
            filterEnabled = false,
            filterIntensityPercent = DEFAULT_PHOTO_FILTER_INTENSITY_PERCENT,
            filterIntensities = mapOf(builtInKey to 64),
            filterAdjustments = mapOf(builtInKey to LutAdjustments(-15)),
        ), cleared)
        val reselected = normalizeLocalPhotoEffectsSettings(cleared.copy(filterId = customId, filterEnabled = true),
            setOf(builtIn.id, customId)) { false }
        assertEquals(DEFAULT_PHOTO_FILTER_INTENSITY_PERCENT, reselected.filterIntensityPercent)
        assertEquals(LutAdjustments(), photoFilterAdjustmentsFor(customId, reselected.filterAdjustments))
    }

    @Test fun directoryReplacementKeepsActiveBuiltInControlsAndClearsExternalHistoryWhileHidden() {
        val builtIn = BuiltInPhotoFilters.all.first()
        val builtInKey = checkNotNull(photoFilterCatalogKey(builtIn.id))
        val customKey = "np3:${"b".repeat(64)}"
        val settings = defaultLocalPhotoEffectsSettings(builtIn.id).copy(
            filterEnabled = true,
            filterIntensityPercent = 56,
            filterIntensities = mapOf(customKey to 26, builtInKey to 56),
            filterAdjustments = mapOf(customKey to LutAdjustments(30), builtInKey to LutAdjustments(-5)),
        )
        val expected = settings.copy(
            filterIntensities = mapOf(builtInKey to 56),
            filterAdjustments = mapOf(builtInKey to LutAdjustments(-5)),
        )
        assertEquals(expected, clearLocalPhotoNp3DirectorySettings(settings))
        assertEquals(expected.copy(filterEnabled = false),
            clearLocalPhotoNp3DirectorySettings(settings.copy(filterEnabled = false)))
    }

    @Test fun customAdjustmentsSurviveDisablingAndMissingSourceWithoutLeakingToOtherFilters() {
        val key = "np3:${"a".repeat(64)}"
        val id = "$key:np3-srgb-v1"
        val controls = LutAdjustments(17, -23, 37, -41)
        val settings = defaultLocalPhotoEffectsSettings(id).copy(
            filterEnabled = true,
            filterAdjustments = mapOf(key to controls, "removed" to LutAdjustments(1)),
        )
        val missing = normalizeLocalPhotoEffectsSettings(settings, setOf("forest")) { false }
        assertFalse(missing.filterEnabled)
        assertEquals(mapOf(key to controls), missing.filterAdjustments)
        assertEquals(LutAdjustments(), photoFilterAdjustmentsFor("forest", missing.filterAdjustments))
        val restored = normalizeLocalPhotoEffectsSettings(missing.copy(filterId = id), setOf(id)) { false }
        val hidden = applyLocalPhotoEffectModuleVisibility(restored,
            ALL_PHOTO_EFFECT_MODULES xor PhotoEffectModule.FILTER.bit)
        assertFalse(hidden.filterEnabled)
        assertEquals(controls, photoFilterAdjustmentsFor(id, hidden.filterAdjustments))
    }

    @Test fun legacyLocalSettingsHaveNeutralControlsForEveryFilter() {
        val restored = normalizeLocalPhotoEffectsSettings(defaultLocalPhotoEffectsSettings("forest"),
            setOf("forest")) { false }
        assertEquals(emptyMap<String, LutAdjustments>(), restored.filterAdjustments)
        assertEquals(LutAdjustments(), photoFilterAdjustmentsFor(restored.filterId, restored.filterAdjustments))
    }

    @Test fun savedCustomSnapshotKeepsSelectionAndUsesItsStableIntensityKey() {
        val key = "np3:${"a".repeat(64)}"
        val id = "$key:np3-srgb-v1"
        val settings = defaultLocalPhotoEffectsSettings(id).copy(
            filterEnabled = true,
            filterIntensityPercent = 80,
            filterIntensities = mapOf(key to 43),
        )
        val restored = normalizeLocalPhotoEffectsSettings(settings, setOf(id)) { false }
        assertEquals(id, restored.filterId)
        assertEquals(true, restored.filterEnabled)
        assertEquals(44, restored.filterIntensityPercent)
        assertEquals(mapOf(key to 44), restored.filterIntensities)
    }

    @Test fun missingCustomSnapshotDisablesSelectionButKeepsItsPreferenceMemory() {
        val key = "np3:${"b".repeat(64)}"
        val settings = defaultLocalPhotoEffectsSettings("$key:np3-srgb-v1").copy(
            filterEnabled = true,
            filterIntensities = mapOf(key to 60, "missing" to 20, "np3:bad" to 30),
        )
        val restored = normalizeLocalPhotoEffectsSettings(settings, setOf("forest")) { false }
        assertNull(restored.filterId)
        assertFalse(restored.filterEnabled)
        assertEquals(mapOf(key to 60), restored.filterIntensities)
    }

    @Test fun hidingTheFilterModuleKeepsCustomMemoriesWithoutReenablingTheEffect() {
        val key = "np3:${"c".repeat(64)}"
        val id = "$key:np3-srgb-v1"
        val original = defaultLocalPhotoEffectsSettings(id).copy(
            filterEnabled = true, filterIntensities = mapOf(key to 26),
        )
        val hidden = applyLocalPhotoEffectModuleVisibility(original,
            ALL_PHOTO_EFFECT_MODULES xor PhotoEffectModule.FILTER.bit)
        val shown = applyLocalPhotoEffectModuleVisibility(hidden, ALL_PHOTO_EFFECT_MODULES)
        val restored = normalizeLocalPhotoEffectsSettings(shown, setOf(id)) { false }
        assertFalse(restored.filterEnabled)
        assertEquals(26, restored.filterIntensityPercent)
    }

    @Test
    fun currentStyleAndOtherStyleMemoriesSurviveNormalizationAndModuleHiding() {
        val intensities = mapOf(PhotoGrainStyle.FINE to 30, PhotoGrainStyle.MEDIUM to 50,
            PhotoGrainStyle.COARSE to 70)
        val original = defaultLocalPhotoEffectsSettings(null).copy(
            grain = PhotoGrainSettings(0, true, PhotoGrainStyle.MEDIUM),
            grainIntensities = intensities,
        )
        val normalized = normalizeLocalPhotoEffectsSettings(original, emptySet()) { false }
        assertEquals(original.grain, normalized.grain)
        assertEquals(intensities + (PhotoGrainStyle.MEDIUM to 0), normalized.grainIntensities)
        val hidden = applyLocalPhotoEffectModuleVisibility(normalized,
            ALL_PHOTO_EFFECT_MODULES xor PhotoEffectModule.GRAIN.bit)
        val shown = applyLocalPhotoEffectModuleVisibility(hidden, ALL_PHOTO_EFFECT_MODULES)
        assertEquals(normalized.grain.copy(enabled = false), shown.grain)
        assertEquals(normalized.grainIntensities, shown.grainIntensities)
    }

    @Test
    fun grainDefaultsOffAndRetainsSwitchAndExactIntensityAcrossNormalization() {
        val settings = defaultLocalPhotoEffectsSettings(null)
        assertEquals(PhotoGrainSettings(50, enabled = false), settings.grain)
        assertEquals(mapOf(PhotoGrainStyle.FINE to 50, PhotoGrainStyle.MEDIUM to 40,
            PhotoGrainStyle.COARSE to 30), settings.grainIntensities)
        for (intensity in listOf(0, 1, 37, 100)) {
            for (enabled in listOf(false, true)) {
                val grain = PhotoGrainSettings(intensity, enabled)
                val restored = normalizeLocalPhotoEffectsSettings(
                    settings.copy(grain = grain), emptySet(),
                ) { false }
                assertEquals(grain, restored.grain)
            }
        }
        assertEquals(PhotoGrainSettings(100, enabled = false), normalizeLocalPhotoEffectsSettings(
            settings.copy(grain = PhotoGrainSettings(120, enabled = false)), emptySet(),
        ) { false }.grain)
        assertEquals(PhotoGrainSettings(0, enabled = true), normalizeLocalPhotoEffectsSettings(
            settings.copy(grain = PhotoGrainSettings(-3, enabled = true)), emptySet(),
        ) { false }.grain)
    }

    @Test
    fun hidingGrainRetainsIntensityAndShowingItAgainDoesNotEnableIt() {
        val original = defaultLocalPhotoEffectsSettings("forest").copy(
            grain = PhotoGrainSettings(37, enabled = true),
            filterEnabled = true, decorationEnabled = true,
        )
        val hidden = applyLocalPhotoEffectModuleVisibility(
            original, ALL_PHOTO_EFFECT_MODULES xor PhotoEffectModule.GRAIN.bit,
        )
        assertEquals(original.copy(grain = PhotoGrainSettings(37, enabled = false)), hidden)
        assertEquals(hidden, applyLocalPhotoEffectModuleVisibility(hidden, ALL_PHOTO_EFFECT_MODULES))
        val restored = normalizeLocalPhotoEffectsSettings(hidden, setOf("forest")) { false }
        assertEquals(PhotoGrainSettings(37, enabled = false), restored.grain)
    }

    @Test
    fun hidingAnAlreadyDisabledGrainDoesNotResetItsRememberedStrength() {
        val original = defaultLocalPhotoEffectsSettings(null).copy(
            grain = PhotoGrainSettings(73, enabled = false),
        )
        assertEquals(original, applyLocalPhotoEffectModuleVisibility(
            original, ALL_PHOTO_EFFECT_MODULES xor PhotoEffectModule.GRAIN.bit,
        ))
    }

    @Test
    fun widthsAreIndependentForEveryPresetAndSurviveWorkbenchNormalization() {
        val values = com.ztransfer.frame.PhotoFramePreset.entries.associateWith {
            com.ztransfer.frame.defaultPhotoFrameMetadataSettings(it).copy(widthPercent = 60 + it.ordinal % 15 * 10)
        }
        val settings = defaultLocalPhotoEffectsSettings(defaultFilterId = null).copy(metadataSettings = values)
        val normalized = normalizeLocalPhotoEffectsSettings(settings, emptySet()) { false }
        for ((preset, value) in values) {
            assertEquals(value.widthPercent,
                com.ztransfer.frame.resolvedPhotoFrameMetadataSettings(normalized.metadataSettings, preset).widthPercent)
        }
    }

    @Test
    fun workbenchHasItsOwnDefaults() {
        val defaults = defaultLocalPhotoEffectsSettings(defaultFilterId = "forest")

        assertFalse(defaults.decorationEnabled)
        assertEquals(true, defaults.borderEnabled)
        assertEquals(PhotoFramePreset.MIST, defaults.preset)
        assertEquals(PhotoFrameWatermark(), defaults.watermark)
        assertEquals(PhotoFrameWatermarkFont.CALLIGRAPHY, defaults.watermark.font)
        assertEquals(80, defaults.watermark.sizePercent)
        assertEquals("forest", defaults.filterId)
        assertFalse(defaults.filterEnabled)
        assertEquals(80, defaults.filterIntensityPercent)
    }

    @Test
    fun invalidPersistedValuesAreNormalizedBeforeEditing() {
        val settings = LocalPhotoEffectsSettings(
            decorationEnabled = true,
            borderEnabled = false,
            preset = PhotoFramePreset.PLAQUE,
            metadataSettings = mapOf(
                PhotoFramePreset.PLAQUE to defaultPhotoFrameMetadataSettings(
                    PhotoFramePreset.PLAQUE,
                ).copy(
                    showAddress = true,
                    showCoordinates = true,
                    showAltitude = true,
                ),
            ),
            watermark = PhotoFrameWatermark(
                content = PhotoFrameWatermarkContent.IMAGE,
                imageHash = "a".repeat(64),
                text = "line one\nline two",
                sizePercent = 999,
                opacityPercent = 0,
            ),
            filterId = "removed-filter",
            filterEnabled = true,
            filterIntensityPercent = 53,
        )

        val restored = normalizeLocalPhotoEffectsSettings(
            settings = settings,
            availableFilterIds = setOf("available-filter"),
            watermarkImageExists = { false },
        )

        assertEquals(PhotoFrameWatermarkContent.TEXT, restored.watermark.content)
        assertNull(restored.watermark.imageHash)
        assertEquals("line one line two", restored.watermark.text)
        assertEquals(300, restored.watermark.sizePercent)
        assertEquals(1, restored.watermark.opacityPercent)
        assertNull(restored.filterId)
        assertFalse(restored.filterEnabled)
        assertEquals(54, restored.filterIntensityPercent)
        val metadata = restored.metadataSettings[PhotoFramePreset.PLAQUE]
            ?: defaultPhotoFrameMetadataSettings(PhotoFramePreset.PLAQUE)
        assertFalse(metadata.showAddress)
        assertFalse(metadata.showCoordinates)
        assertFalse(metadata.showAltitude)
    }

    @Test
    fun validWatermarkAndFilterSettingsRemainSelected() {
        val hash = "b".repeat(64)
        val settings = LocalPhotoEffectsSettings(
            decorationEnabled = true,
            borderEnabled = true,
            preset = PhotoFramePreset.MIST,
            watermark = PhotoFrameWatermark(
                content = PhotoFrameWatermarkContent.IMAGE,
                imageHash = hash,
            ),
            filterId = "forest",
            filterEnabled = true,
            filterIntensityPercent = 80,
        )

        val restored = normalizeLocalPhotoEffectsSettings(
            settings = settings,
            availableFilterIds = setOf("forest"),
            watermarkImageExists = { it == hash },
        )

        assertEquals(
            settings.copy(filterIntensities = mapOf("forest" to 80)),
            restored,
        )
    }

    @Test
    fun workbenchKeepsIndependentIntensityForEachFilter() {
        val settings = defaultLocalPhotoEffectsSettings(defaultFilterId = "forest").copy(
            filterIntensityPercent = 80,
            filterIntensities = mapOf(
                "forest" to 45,
                "removed-filter" to 62,
            ),
        )

        val restored = normalizeLocalPhotoEffectsSettings(
            settings = settings,
            availableFilterIds = setOf("forest"),
            watermarkImageExists = { false },
        )

        assertEquals(46, restored.filterIntensityPercent)
        assertEquals(mapOf("forest" to 46), restored.filterIntensities)
    }
}
