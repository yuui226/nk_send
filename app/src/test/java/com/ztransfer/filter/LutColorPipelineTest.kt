package com.ztransfer.filter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class LutColorPipelineTest {
    @Test fun neutralAdjustmentsKeepPixelsByteExact() {
        val color = 0x80406080.toInt()
        assertEquals(color, LutColorPipeline.apply(color, LutAdjustments(), true))
    }

    @Test fun saturationDoesNotChangeGrayPixels() {
        val gray = 0xff808080.toInt()
        assertEquals(gray, LutColorPipeline.apply(gray, LutAdjustments(saturation = 100), false))
    }

    @Test fun toneAndContrastStayInValidArgbRange() {
        val result = LutColorPipeline.apply(
            0xff102030.toInt(),
            LutAdjustments(contrast = 100, saturation = 100, highlights = 100, shadows = -100),
            false,
        )
        assertEquals(0xff, result ushr 24 and 0xff)
        assert((result and 0x00ffffff) in 0..0x00ffffff)
        assertNotEquals(0xff102030.toInt(), result)
    }

    @Test fun transparentPixelsRemainTransparent() {
        val color = 0x00112233
        assertEquals(color, LutColorPipeline.apply(color, LutAdjustments(contrast = 100), true))
    }
}
