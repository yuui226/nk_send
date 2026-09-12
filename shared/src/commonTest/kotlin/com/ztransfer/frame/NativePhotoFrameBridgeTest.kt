package com.ztransfer.frame

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class NativePhotoFrameBridgeTest {
    @Test
    fun resolvesEveryBuiltInPresetByNameAndSuffix() {
        PhotoFramePreset.entries.forEach { preset ->
            assertTrue(NativePhotoFrameBridge.isSupportedPreset(preset.name))
            assertTrue(NativePhotoFrameBridge.isSupportedPreset(preset.fileSuffix))
            assertNotNull(
                NativePhotoFrameBridge.layout(
                    presetName = preset.name,
                    sourceWidth = 6000,
                    sourceHeight = 4000,
                    originalQuality = false,
                ),
            )
        }
    }

    @Test
    fun originalQualityKeepsThePhotoAtSourceSize() {
        PhotoFramePreset.entries.forEach { preset ->
            val layout = assertNotNull(
                NativePhotoFrameBridge.layout(
                    presetName = preset.fileSuffix,
                    sourceWidth = 6000,
                    sourceHeight = 4000,
                    originalQuality = true,
                ),
            )
            assertTrue(layout.photoRight - layout.photoLeft >= 6000f, "${preset.name} width=${layout.photoRight - layout.photoLeft}")
            assertTrue(layout.photoBottom - layout.photoTop >= 4000f, "${preset.name} height=${layout.photoBottom - layout.photoTop}")
        }
    }

    @Test
    fun unknownPresetIsSafeToProbe() {
        assertFalse(NativePhotoFrameBridge.isSupportedPreset("unknown"))
        assertNull(
            NativePhotoFrameBridge.layout(
                presetName = "unknown",
                sourceWidth = 6000,
                sourceHeight = 4000,
                originalQuality = false,
            ),
        )
    }
}
