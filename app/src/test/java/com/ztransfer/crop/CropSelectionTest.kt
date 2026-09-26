package com.ztransfer.crop

import org.junit.Assert.*
import org.junit.Test

class CropSelectionTest {
    @Test fun deferredSelectionResolvesAgainstEveryOriginalOrientationAndResolution() {
        val bounds=CropBounds(.2,.25,.8,.75)
        for (orientation in 1..8) for (width in listOf(6000,12000)) {
            val source=JpegCropSource(width,width*2/3,16,8,orientation)
            val selected=JpegCropSelection(bounds,orientation)
            val resolved=selected.resolve(source)
            source.validate(resolved.rect)
            val actual=source.displayBounds(resolved.rect)
            assertEquals(bounds.left,actual.left,16.0/source.displayWidth)
            assertEquals(bounds.top,actual.top,16.0/source.displayHeight)
            assertEquals(bounds.right-bounds.left,actual.right-actual.left,1e-9)
            assertEquals(bounds.bottom-bounds.top,actual.bottom-actual.top,1e-9)
        }
    }
    @Test fun fixedRatioSurvivesDeferredMappingAndDirectionMismatchFails() {
        val selected=JpegCropSelection(CropBounds(.2,.2,.8,.8),6,16,9)
        val source=JpegCropSource(6000,4000,16,8,6)
        val recipe=selected.resolve(source)
        assertEquals(16.0/9,recipe.rect.height.toDouble()/recipe.rect.width,1e-9)
        assertTrue(runCatching {selected.resolve(source.copy(orientation=1))}.isFailure)
    }
    @Test fun orientationReadDoesNotRequireSofOrCompleteOriginalHeader() {
        val exif=byteArrayOf(69,120,105,102,0,0,73,73,42,0,8,0,0,0,1,0,
            0x12,1,3,0,1,0,0,0,6,0,0,0,0,0,0,0)
        val jpeg=byteArrayOf(-1,-40,-1,-31,0,(exif.size+2).toByte())+exif
        assertEquals(6,parseJpegCropOrientation(jpeg))
        assertNull(parseJpegCropHeader(jpeg))
    }
    @Test fun paddingIsExcludedWithoutRequiringOriginalDimensions() {
        val white=0xFFFFFF
        assertEquals(CropRect(15,0,177,108),cropPreviewBounds(192,108){x,_->if(x<15||x>=177)0 else white})
        assertEquals(CropRect(60,0,132,108),cropPreviewBounds(192,108){x,_->if(x<60||x>=132)0 else white})
        assertEquals(CropRect(0,0,192,108),cropPreviewBounds(192,108){_,_->0})
        assertEquals(CropRect(0,0,192,108),cropPreviewBounds(192,108){x,_->if(x<15)0 else white})
        assertEquals(1,cropPreviewOrientation(6,1,720,1080))
        assertEquals(6,cropPreviewOrientation(6,null,1620,1080))
        assertEquals(3,cropPreviewOrientation(3,3,1620,1080))
    }
}
