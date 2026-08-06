package com.ztransfer.filter

import java.security.MessageDigest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class BuiltInPhotoFiltersTest {
    @Test
    fun builtInSetContainsFiveDistinctConvertedPresets() {
        val filters = BuiltInPhotoFilters.all

        assertEquals(5, filters.size)
        assertEquals(
            listOf(
                "Kodak Ektar Green",
                "Kodak-Sun-Nature-02",
                "MSLT-Portra400-V1",
                "cineblue brandon",
                "britfilm bw",
            ),
            filters.map { it.name },
        )
        assertEquals(filters.size, filters.map { it.id }.distinct().size)
        filters.forEach { filter ->
            assertTrue(filter.id.matches(Regex("[0-9a-f]{64}")))
            assertTrue(BuiltInPhotoFilters.nameResId(filter.id) != null)
        }
    }

    @Test
    fun sourceIdentityAndSupportedNp3ControlsRemainStable() {
        val filters = BuiltInPhotoFilters.all
        val ektar = BuiltInPhotoFilters.all[0]
        val nature = BuiltInPhotoFilters.all[1]
        val portra = BuiltInPhotoFilters.all[2]
        val cineBlue = BuiltInPhotoFilters.all[3]
        val silver = BuiltInPhotoFilters.all[4]

        assertEquals(
            listOf(
                "1b6ec047f8e8159fa0595f3ae55e504b9af14acddd0c46d8531571d015d3624c",
                "ed73bfbc40c576b9c152140a3cd4bdb6c3cf90df6bf1d1aa5d362d0569dedc79",
                "a247d4033b0c11acb864dcf03c7355d213e39e81c4030bedb71067e7ca5f14f7",
                "079ca263bcef213f804aa4f49b3d3a4570828647c4d8563860f147d2128ee778",
                "644e9710e38197be33257f0562f89dc3882642e36be6d2b295f82f813597a6d7",
            ),
            filters.map { it.id },
        )

        val ektarParameters = ektar.parameters as NcpPhotoFilterParameters
        val natureParameters = nature.parameters as NcpPhotoFilterParameters
        assertEquals(1, ektarParameters.saturationStep)
        assertEquals(1, ektarParameters.hueStep)
        assertEquals(0x0505, ektarParameters.toneCurve.first())
        assertEquals(0x0383, natureParameters.toneCurve.first())
        assertEquals(
            "7d4eced324272d812907559cafa628e8b6320b21efd32cca69609a1d4acc8c5d",
            toneCurveSha256(ektarParameters.toneCurve),
        )
        assertEquals(
            "9f34a470afb614f76d4d1b9ea8a5c21f8e383756f49380efd5902be45d2ff1a2",
            toneCurveSha256(natureParameters.toneCurve),
        )

        val portraParameters = portra.parameters as Np3PhotoFilterParameters
        assertEquals(11, portraParameters.colorBands[0].hue)
        assertEquals(-16, portraParameters.colorBands[5].hue)
        assertEquals(11, portraParameters.colorBands[5].brightness)
        assertEquals(
            "3e2a4eb44786f539f4ef14d0db034d98b15e902c25f7917b35586bfd232c881b",
            toneCurveSha256(requireNotNull(portraParameters.toneCurve)),
        )

        val cineBlueParameters = cineBlue.parameters as Np3PhotoFilterParameters
        assertEquals(-5, cineBlueParameters.saturation)
        assertEquals(78, cineBlueParameters.colorBands[4].chroma)
        assertEquals(100, cineBlueParameters.colorBands[5].chroma)
        assertEquals(
            "4700e2c82549d7c475119be74539f2d0594484422fb37afe6f789219b2f5e5d3",
            toneCurveSha256(requireNotNull(cineBlueParameters.toneCurve)),
        )

        val silverParameters = silver.parameters as Np3PhotoFilterParameters
        assertEquals(3, silverParameters.contrast)
        assertEquals(-20, silverParameters.highlights)
        assertEquals(31, silverParameters.shadows)
        assertEquals(-34, silverParameters.whites)
        assertEquals(-10, silverParameters.blacks)
        assertEquals(-98, silverParameters.saturation)
        assertEquals(null, silverParameters.toneCurve)
    }

    @Test
    fun unknownImportedPresetHasNoBuiltInLabel() {
        assertEquals(null, BuiltInPhotoFilters.nameResId("f".repeat(64)))
    }

    private fun toneCurveSha256(curve: IntArray): String {
        val bytes = ByteArray(curve.size * 2)
        curve.forEachIndexed { index, value ->
            bytes[index * 2] = (value ushr 8).toByte()
            bytes[index * 2 + 1] = value.toByte()
        }
        return MessageDigest.getInstance("SHA-256")
            .digest(bytes)
            .joinToString("") { byte ->
                (byte.toInt() and 0xff).toString(16).padStart(2, '0')
            }
    }
}
