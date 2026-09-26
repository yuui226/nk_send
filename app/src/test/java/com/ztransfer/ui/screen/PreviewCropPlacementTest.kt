package com.ztransfer.ui.screen

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import com.ztransfer.crop.*
import org.junit.Assert.*
import org.junit.Test

class PreviewCropPlacementTest {
    @Test fun enteringAndChangingRatioPreserveExistingPhotoPlacement() {
        val geometry=CropEditorGeometry(JpegCropSource(1620,1080,1,1,1))
        val photo=Rect(40f,800f,1040f,1466.6667f)
        geometry.initialize(Size(1080f,2400f),photo)
        assertEquals(photo,geometry.image)
        assertEquals(photo,geometry.frame)
        geometry.select(CropRatio.SQUARE)
        assertEquals(photo,geometry.image)
        assertEquals(geometry.frame.width,geometry.frame.height,.001f)
        geometry.transform(geometry.frame.center,Offset(12f,-5f),2f)
        geometry.reset()
        assertEquals(photo,geometry.image)
        assertEquals(photo,geometry.frame)
    }
    @Test fun alreadyZoomedPhotoStartsWithoutRefitting() {
        val photo=Rect(-540f,200f,1620f,1640f)
        val geometry=CropEditorGeometry(JpegCropSource(1620,1080,1,1,1))
        geometry.initialize(Size(1080f,2400f),photo)
        assertEquals(photo,geometry.image)
        assertEquals(Rect(0f,200f,1080f,1640f),geometry.frame)
        val selection=geometry.selection(1)
        assertEquals(.25,selection.bounds.left,1e-9)
        assertEquals(.75,selection.bounds.right,1e-9)
    }
    @Test fun manualPreviewRotationMapsBackToSamePhotoRegion() {
        val original=CropBounds(.12,.23,.62,.83)
        for(manual in listOf(1,3,6,8)) for(canonical in 1..8) {
            val screen=transformCropBounds(original,manual)
            val restored=transformCropBounds(screen,manual,inverse=true)
            val expected=transformCropBounds(original,canonical)
            val actual=transformCropBounds(restored,canonical)
            assertEquals(expected.left,actual.left,1e-9)
            assertEquals(expected.top,actual.top,1e-9)
            assertEquals(expected.right,actual.right,1e-9)
            assertEquals(expected.bottom,actual.bottom,1e-9)
        }
    }
}
