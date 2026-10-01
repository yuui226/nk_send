package com.ztransfer.ui.screen

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import com.ztransfer.crop.JpegCropSource
import org.junit.Assert.*
import org.junit.Test

class CropEditorGeometryTest {
    @Test fun gesturesAndAllRatiosRemainInsideImageAcrossPortraitAndLandscape() {
        for (orientation in 1..8) {
            val source = JpegCropSource(6048,4024,16,8,orientation)
            val editor = CropEditorGeometry(source)
            editor.resize(Size(900f,1500f))
            for (ratio in CropRatio.entries) {
                editor.select(ratio)
                editor.transform(editor.frame.center,Offset(9000f,-8000f),3f)
                source.validate(editor.recipe().rect)
                val shown=editor.alignedFrame()
                assertTrue("orientation=$orientation ratio=$ratio frame=$shown image=${editor.image}", shown.left >= -1f && shown.top >= -1f)
                assertTrue(shown.right <= editor.size.width+1f && shown.bottom <= editor.size.height+1f)
                editor.dragCorner(0,Offset(70f,60f),48f)
                source.validate(editor.recipe().rect)
                val before=editor.recipe()
                editor.resize(Size(1500f,900f))
                val after=editor.recipe()
                // At most a block of rounding from float screen transforms; never a different quadrant.
                assertTrue(kotlin.math.abs(before.rect.left-after.rect.left)<=16)
                assertTrue(kotlin.math.abs(before.rect.top-after.rect.top)<=8)
                editor.transform(Offset(Float.NaN,Float.NaN),Offset.Zero,1f)
                source.validate(editor.recipe().rect)
            }
        }
    }
    @Test fun originalOddDimensionsAllowUsefulSmallCrops() {
        val source=JpegCropSource(6017,4003,16,8,1)
        val editor=CropEditorGeometry(source)
        editor.resize(Size(1080f,1600f))
        editor.transform(editor.frame.center,Offset.Zero,2f)
        val crop=editor.recipe().rect
        assertTrue(crop.width in 3000..3010)
        assertTrue(crop.height in 1995..2005)
        editor.reset()
        assertEquals(6017,editor.recipe().rect.width)
        assertEquals(4003,editor.recipe().rect.height)
    }
    @Test fun repeatedPortraitLandscapeChangesDoNotAccumulateShrinkage() {
        val editor=CropEditorGeometry(JpegCropSource(6000,4000,1,1,1))
        editor.resize(Size(1080f,1920f))
        val image=editor.image
        val original=editor.frame
        repeat(20) {
            editor.select(CropRatio.SQUARE)
            val square=editor.frame
            for (ratio in listOf(CropRatio.NINE_SIXTEEN,CropRatio.THREE_TWO,CropRatio.FOUR_FIVE,CropRatio.SIXTEEN_NINE)) {
                editor.select(ratio)
                assertEquals(ratio.width.toFloat()/ratio.height,editor.frame.width/editor.frame.height,.0001f)
                assertEquals(image,editor.image)
            }
            editor.select(CropRatio.SQUARE)
            assertEquals(square,editor.frame)
            editor.select(CropRatio.ORIGINAL)
            assertEquals(original,editor.frame)
        }
    }
    @Test fun manuallyResizedFrameBecomesTheStableRatioReference() {
        val editor=CropEditorGeometry(JpegCropSource(6000,4000,1,1,1))
        editor.resize(Size(1080f,1920f))
        editor.select(CropRatio.SQUARE)
        editor.dragCorner(0,Offset(100f,100f),48f)
        val manual=editor.frame
        repeat(5) {
            editor.select(CropRatio.NINE_SIXTEEN)
            editor.select(CropRatio.SQUARE)
            assertEquals(manual,editor.frame)
        }
    }
    @Test fun explicitPortraitOptionsAreNotInvertedByAPreviousSwap() {
        val editor=CropEditorGeometry(JpegCropSource(6000,4000,1,1,1))
        editor.resize(Size(1080f,1920f))
        editor.select(CropRatio.THREE_TWO)
        val before=editor.frame
        editor.select(editor.ratio,flip=true)
        assertEquals(CropRatio.TWO_THREE,editor.ratio)
        editor.select(editor.ratio,flip=true)
        assertEquals(CropRatio.THREE_TWO,editor.ratio)
        assertEquals(before,editor.frame)
        editor.select(CropRatio.TWO_ONE)
        editor.select(editor.ratio,flip=true)
        editor.select(CropRatio.NINE_SIXTEEN)
        assertFalse(editor.swapped)
        assertEquals(9f/16,editor.frame.width/editor.frame.height,.0001f)
    }
}
