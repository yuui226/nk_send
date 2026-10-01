package com.ztransfer.effects

import org.junit.Assert.*
import org.junit.Test

class PhotoEffectModulesTest {
    @Test fun everyToggleRetainsAtLeastOneModule() {
        for (mask in 1..ALL_PHOTO_EFFECT_MODULES) {
            for (module in PhotoEffectModule.entries) {
                val next = togglePhotoEffectModule(mask, module)
                assertTrue(next in 1..ALL_PHOTO_EFFECT_MODULES)
                if (mask == module.bit) assertEquals(mask, next)
                else assertEquals(mask xor module.bit, next)
            }
        }
    }
    @Test fun freeEditionBindsFrameAndWatermarkAndNeverAllowsAnEmptyEditor() {
        for (mask in 1..ALL_PHOTO_EFFECT_MODULES) {
            val effective = effectivePhotoEffectModules(mask, false)
            assertEquals(effective.showsPhotoEffect(PhotoEffectModule.FRAME),
                effective.showsPhotoEffect(PhotoEffectModule.WATERMARK))
            for (module in PhotoEffectModule.entries) {
                val next = togglePhotoEffectModule(effective, module, false)
                assertTrue(next > 0)
                assertEquals(next.showsPhotoEffect(PhotoEffectModule.FRAME),
                    next.showsPhotoEffect(PhotoEffectModule.WATERMARK))
            }
            assertEquals(mask, effectivePhotoEffectModules(mask, true))
        }
        assertEquals(12, togglePhotoEffectModule(12, PhotoEffectModule.FRAME, false))
        assertEquals(1, togglePhotoEffectModule(13, PhotoEffectModule.WATERMARK, false))
        assertEquals(13, togglePhotoEffectModule(1, PhotoEffectModule.FRAME, false))
    }
    @Test fun invalidEmptyConfigurationRestoresAllModules() {
        assertEquals(ALL_PHOTO_EFFECT_MODULES, normalizePhotoEffectModules(0))
        assertEquals(ALL_PHOTO_EFFECT_MODULES, normalizePhotoEffectModules(16))
        assertEquals(1, normalizePhotoEffectModules(17))
    }
}
