package com.ztransfer.filter

import com.ztransfer.lut.CubeLutParser
import org.junit.Assert.*
import org.junit.Test
import kotlin.math.roundToInt

class PhotoCubeMapperTest {
    private fun cube(size: Int, transform: (Float,Float,Float) -> List<Float>) = CubeLutParser.parse(buildString {
        append("LUT_3D_SIZE $size\n")
        for (b in 0 until size) for (g in 0 until size) for (r in 0 until size)
            append(transform(r.toFloat()/(size-1),g.toFloat()/(size-1),b.toFloat()/(size-1)).joinToString(" ")).append('\n')
    }.byteInputStream())

    @Test fun identityKeepsPixelsAndAlphaAtEverySupportedCommonGrid() {
        for (size in listOf(2,17,33,65)) {
            val mapper = PhotoCubeMapper(cube(size) { r,g,b -> listOf(r,g,b) })
            for (r in 0..255 step 7) for (g in 0..255 step 11) for (b in 0..255 step 13) {
                val color = (127 shl 24) or (r shl 16) or (g shl 8) or b
                for (strength in listOf(.02f,.5f,1f)) assertEquals(color, mapper.map(color, strength, true))
            }
            assertEquals(0xffffffff.toInt(), mapper.map(0xffffffff.toInt(), 1f, true))
            assertEquals(0x00123456, mapper.map(0x00123456, 1f, true))
        }
    }
    @Test fun channelOrderingAndStrengthMatchAnalyticalTransform() {
        val mapper = PhotoCubeMapper(cube(17) { r,g,b -> listOf(b, 1f-r, g) })
        for (value in 0..255) {
            val r=value; val g=255-value; val b=value/2
            val input=(255 shl 24) or (r shl 16) or (g shl 8) or b
            for (s in listOf(.02f,.3f,1f)) {
                val expected=(255 shl 24) or ((r+(b-r)*s).roundToInt() shl 16) or
                    ((g+(255-r-g)*s).roundToInt() shl 8) or (b+(g-b)*s).roundToInt()
                val actual=mapper.map(input,s,false)
                for (shift in listOf(0,8,16)) assertTrue(kotlin.math.abs((expected ushr shift and 255)-(actual ushr shift and 255)) <= 1)
            }
        }
    }
    @Test fun domainAndExtendedOutputClampBeforeStrengthMixing() {
        val text="DOMAIN_MIN 0.25 0.25 0.25\nDOMAIN_MAX 0.75 0.75 0.75\nLUT_3D_SIZE 2\n"+
            (0..7).joinToString("\n") { "-0.5 1.5 0.5" }
        val mapper=PhotoCubeMapper(CubeLutParser.parse(text.byteInputStream()))
        assertEquals(0xff00ff80.toInt(), mapper.map(0xff804020.toInt(),1f,false))
        assertEquals(0xff40a050.toInt(), mapper.map(0xff804020.toInt(),.5f,false))
    }
    @Test fun cubeExportDoesNotAllocateAnExactColorMemo() {
        val selection=PhotoFilterSelection(PhotoFilterPreset("cube:test","Identity",CubePhotoFilterParameters(cube(2){r,g,b->listOf(r,g,b)})),100)
        val prepared=PhotoFilterRenderer.prepareOriginalFilter(selection)
        assertNull(prepared.exactRgbMemo)
        assertSame(selection,prepared.selection)
    }
}
