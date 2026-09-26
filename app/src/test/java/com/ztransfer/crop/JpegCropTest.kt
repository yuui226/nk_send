package com.ztransfer.crop

import org.junit.Assert.*
import org.junit.Test

class JpegCropTest {
    @Test fun allExifOrientationsRoundTripAndKeepFixedRatio() {
        for (orientation in 1..8) {
            val source = JpegCropSource(6048, 4024, 16, 8, orientation)
            for (point in listOf(CropPoint(0.0, 0.0), CropPoint(1.0, 1.0), CropPoint(0.17, 0.81))) {
                val display = source.toDisplay(point.x, point.y)
                val back = source.toSource(display.x, display.y)
                assertEquals(point.x, back.x, 1e-9)
                assertEquals(point.y, back.y, 1e-9)
            }
            for ((rw, rh) in listOf(1 to 1, 3 to 2, 2 to 3, 16 to 9, 9 to 16, 5 to 4)) {
                val rect = source.align(CropBounds(.137, .219, .881, .934), rw, rh)
                source.validate(rect)
                val display = source.displayBounds(rect)
                val w = (display.right - display.left) * source.displayWidth
                val h = (display.bottom - display.top) * source.displayHeight
                assertEquals(rw.toDouble() / rh, w / h, 1e-9)
                val restored = source.align(display, rw, rh)
                assertEquals(rect, restored)
            }
        }
    }
    @Test fun edgeCropsNeverExtendBeyondSourceOrChangeAfterConfirmation() {
        for (orientation in 1..8) for (mcu in listOf(8, 16, 32)) {
            val source = JpegCropSource(6017, 4003, mcu, 8, orientation)
            for (bounds in listOf(CropBounds(0.0,0.0,1.0,1.0), CropBounds(.99,.98,1.0,1.0))) {
                val rect = source.align(bounds)
                source.validate(rect)
                assertEquals(rect, source.align(source.displayBounds(rect)))
            }
        }
    }
    @Test fun originalRatioDoesNotTrimFullImage() {
        val source = JpegCropSource(6048, 4024, 16, 8, 6)
        assertEquals(CropRect(0, 0, 6048, 4024), source.align(CropBounds(0.0,0.0,1.0,1.0),4024,6048))
    }
    @Test fun headerRequiresRealSofAndScanNotEmbeddedThumbnail() {
        val jpeg = byteArrayOf(-1,-40, -1,-64, 0,17, 8, 15,-96, 23,112, 3, 1,0x21,0, 2,0x11,1, 3,0x11,1, -1,-38,0,2)
        assertEquals(JpegCropSource(6000,4000,16,8,1), parseJpegCropHeader(jpeg))
        assertNull(parseJpegCropHeader(jpeg.copyOf(21)))
        assertNull(parseJpegCropHeader(byteArrayOf(1,2,3,4)))
    }
}
