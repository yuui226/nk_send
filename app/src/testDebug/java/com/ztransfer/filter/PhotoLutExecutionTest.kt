package com.ztransfer.filter

import com.ztransfer.lut.CubeLut
import org.junit.Assert.*
import org.junit.Test

class PhotoLutExecutionTest {
    @Test fun exportUsesNative16KWhenAvailableOtherwiseKotlin() {
        val parameters = CubePhotoFilterParameters(CubeLut(2, floatArrayOf(0f,0f,0f),
            floatArrayOf(1f,1f,1f), FloatArray(24), "test"))
        val selection = PhotoFilterSelection(PhotoFilterPreset("lut:test", "test", parameters), 80)
        val prepared = PhotoFilterRenderer.prepareOriginalFilter(selection)
        assertEquals(if (NativePhotoLut.available) PhotoLutExecution.NATIVE_16K else PhotoLutExecution.KOTLIN,
            prepared.cubeExecution)
    }
}
