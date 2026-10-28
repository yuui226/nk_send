package com.ztransfer.lut

import com.ztransfer.filter.LutAdjustments
import org.junit.Assert.assertEquals
import org.junit.Test

class PhotoLutParameterMemoryTest {
    private val digest = "a".repeat(64)
    private val uri = "content://lut/document/a"

    @Test fun eachEditorsAppliedRecipeWinsOverThePreviouslySharedValues() {
        val old = mapOf<String, Any>(
            "transfer:digest" to digest, "local:digest" to digest,
            "transfer:strength" to 42, "local:strength" to 88,
            "transfer:adjustments:contrast" to 15, "local:adjustments:contrast" to -20,
            "lut_adjustments_v1:$digest:intensity" to 70,
            "lut_adjustments_v1:$digest:contrast" to 60,
            "lut_adjustments_v1:$digest:saturation" to 50,
        )
        assertEquals(PhotoLutParameterMemory(42, LutAdjustments(contrast = 15)),
            resolvePhotoLutParameterMemory(old, "transfer", digest, uri))
        assertEquals(PhotoLutParameterMemory(88, LutAdjustments(contrast = -20)),
            resolvePhotoLutParameterMemory(old, "local", digest, uri))
    }

    @Test fun roleMemoryIsAuthoritativeAndNeverFallsBackToAnotherEditor() {
        val own = photoLutMemoryKey("transfer", digest)
        val other = photoLutMemoryKey("local", digest)
        val values = mapOf<String, Any>(
            "$own:intensity" to 54, "$own:contrast" to 0,
            "$other:intensity" to 92, "$other:contrast" to 40,
            "transfer:digest" to digest, "transfer:strength" to 76,
            "transfer:adjustments:contrast" to 20,
            "lut_adjustments_v1:$digest:intensity" to 66,
            "lut_adjustments_v1:$digest:saturation" to 90,
        )
        assertEquals(PhotoLutParameterMemory(54, LutAdjustments()),
            resolvePhotoLutParameterMemory(values, "transfer", digest, uri))
        assertEquals(PhotoLutParameterMemory(92, LutAdjustments(contrast = 40)),
            resolvePhotoLutParameterMemory(values, "local", digest, uri))
    }

    @Test fun uriOnlyLegacyStrengthMigratesWithOrWithoutTheCurrentUriArgument() {
        val values = mapOf<String, Any>("strength:$uri" to 35,
            "transfer:digest" to digest, "transfer:uri" to uri,
            "lut_adjustments_v1:$digest:highlights" to -37)
        val expected = PhotoLutParameterMemory(36, LutAdjustments(highlights = -37))
        assertEquals(expected, resolvePhotoLutParameterMemory(values, "transfer", digest, null))
        assertEquals(expected, resolvePhotoLutParameterMemory(values, "local", digest, uri))
        assertEquals(80, resolvePhotoLutParameterMemory(values, "local", digest, null).intensityPercent)
    }

    @Test fun digestMemoryBeatsLegacyUriAndAnotherAppliedFileDoesNotLeak() {
        val otherDigest = "b".repeat(64)
        val values = mapOf<String, Any>("transfer:digest" to otherDigest,
            "transfer:strength" to 20, "transfer:adjustments:shadows" to -80,
            "strength:$uri" to 30, "lut_adjustments_v1:$digest:intensity" to 65,
            "lut_adjustments_v1:$digest:shadows" to 75)
        assertEquals(PhotoLutParameterMemory(66, LutAdjustments(shadows = 75)),
            resolvePhotoLutParameterMemory(values, "transfer", digest, uri))
    }

    @Test fun corruptScopedValuesRemainNeutralInsteadOfReimportingSharedState() {
        val key = photoLutMemoryKey("transfer", digest)
        val values = mapOf<String, Any>("$key:intensity" to "bad", "$key:contrast" to "bad",
            "$key:saturation" to 120, "$key:shadows" to -120,
            "lut_adjustments_v1:$digest:intensity" to 20,
            "lut_adjustments_v1:$digest:contrast" to 90)
        assertEquals(PhotoLutParameterMemory(80, LutAdjustments(saturation = 100, shadows = -100)),
            resolvePhotoLutParameterMemory(values, "transfer", digest, uri))
        assertEquals(PhotoLutParameterMemory(80, LutAdjustments()),
            resolvePhotoLutParameterMemory(emptyMap<String, Any?>(), "local", digest, null))
    }

    @Test(expected = IllegalArgumentException::class)
    fun unknownEditorCannotSilentlyShareAnotherEditorsMemory() {
        photoLutMemoryKey("monitor", digest)
    }
}
