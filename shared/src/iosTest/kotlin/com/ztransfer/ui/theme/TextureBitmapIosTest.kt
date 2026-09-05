package com.ztransfer.ui.theme

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** Mac simulator gate: these tests are not executable on Windows. */
class TextureBitmapIosTest {
    @Test fun opaqueColorsKeepRgbaOrderAfterTemporaryImageIsClosed() {
        val source = intArrayOf(0xffff0000.toInt(), 0xff00ff00.toInt(), 0xff0000ff.toInt(), 0xff123456.toInt())
        val image = createTextureImageBitmap(source, 2, 2)
        source.fill(0) // Output must own pixels, not a temporary Kotlin input buffer.
        val result = IntArray(4)
        image.readPixels(result)
        assertEquals(2, image.width)
        assertEquals(2, image.height)
        assertContentEquals(intArrayOf(0xffff0000.toInt(), 0xff00ff00.toInt(), 0xff0000ff.toInt(), 0xff123456.toInt()), result)
    }

    @Test fun translucentPixelsAreNotTreatedAsOpaqueOrPremultipliedInput() {
        val image = createTextureImageBitmap(intArrayOf(0x80ff0000.toInt(), 0x00112233), 2, 1)
        val result = IntArray(2)
        image.readPixels(result)
        assertTrue((result[0] ushr 24) in 127..129)
        assertTrue(((result[0] ushr 16) and 255) >= 254)
        assertEquals(0, result[0] and 0xffff)
        assertEquals(0, result[1] ushr 24)
    }
}
