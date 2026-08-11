package com.ztransfer.filter

import java.security.MessageDigest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BuiltInPhotoFiltersTest {
    @Test
    fun builtInSetContainsFiftyDistinctCuratedNp3Presets() {
        val filters = BuiltInPhotoFilters.all

        assertEquals(50, filters.size)
        assertEquals(
            listOf(
                "Forest Verdure",
                "Dusk Ember",
                "Bleached Silver",
                "Blue Hour",
                "Blue Memory",
                "British Mono",
                "Love Glow",
                "Calm Breeze",
                "Cinema Blue",
                "Cinematic Dusk",
                "Clear Portrait",
                "Cozy Autumn",
                "Dawn Hues",
                "Darkroom Film",
                "Fern Shade",
                "Classic Film",
                "Golden Dusk",
                "Soft Harmony",
                "Urban Green",
                "Matte Blue",
                "Moss Mood",
                "Green Shadows",
                "Soft Portrait",
                "Natural Link",
                "Cyan Negative",
                "Red Cyan",
                "Teal Negative",
                "Lemon Negative",
                "Amber Negative",
                "Lime Negative",
                "Pastel Pink",
                "Rose Vintage",
                "Setouchi Blue",
                "Sky Mist",
                "Soft Film",
                "Soft Glow",
                "Cool Sun Kiss",
                "Warm Sun Kiss",
                "Sunset Film",
                "Sunset Glow",
                "Teal and Orange",
                "Gentle Clarity",
                "Turquoise Blue",
                "Vintage Color",
                "Vintage Vibe",
                "Vital Film",
                "Warm Street",
                "Warm Lowlight",
                "Warm Portrait",
                "Honey Warm",
            ),
            filters.map { it.name },
        )
        assertEquals(filters.size, filters.map { it.id }.distinct().size)
        assertEquals(
            filters.size,
            filters.mapNotNull { BuiltInPhotoFilters.catalogKey(it.id) }.distinct().size,
        )
        filters.forEach { filter ->
            assertTrue(filter.id.matches(Regex("[0-9a-f]{64}")))
            assertNotNull(BuiltInPhotoFilters.nameResId(filter.id))
            assertTrue(BuiltInPhotoFilters.catalogKey(filter.id)?.matches(Regex("[0-9a-f]{64}")) == true)
            assertTrue(filter.parameters is Np3PhotoFilterParameters)
        }
    }

    @Test
    fun curatedSetContainsNoIdenticalEffects() {
        val fingerprints = BuiltInPhotoFilters.all.map { filter ->
            val parameters = filter.parameters as Np3PhotoFilterParameters
            buildString {
                append(
                    listOf(
                        parameters.contrast,
                        parameters.highlights,
                        parameters.shadows,
                        parameters.whites,
                        parameters.blacks,
                        parameters.saturation,
                    ).joinToString(","),
                )
                parameters.colorBands.forEach { band ->
                    append("|")
                    append(band.hue)
                    append(",")
                    append(band.chroma)
                    append(",")
                    append(band.brightness)
                }
                append("|")
                append(parameters.toneCurve?.joinToString(",") ?: "none")
            }
        }

        assertEquals(fingerprints.size, fingerprints.distinct().size)
    }

    @Test
    fun representativeSourceIdentityAndNp3ControlsRemainStable() {
        val britishMono = BuiltInPhotoFilters.all[5]
        val cinemaBlue = BuiltInPhotoFilters.all[8]
        val softPortrait = BuiltInPhotoFilters.all[22]

        assertEquals(
            "644e9710e38197be33257f0562f89dc3882642e36be6d2b295f82f813597a6d7",
            britishMono.id,
        )
        assertEquals(
            "079ca263bcef213f804aa4f49b3d3a4570828647c4d8563860f147d2128ee778",
            cinemaBlue.id,
        )
        assertEquals(
            "a247d4033b0c11acb864dcf03c7355d213e39e81c4030bedb71067e7ca5f14f7",
            softPortrait.id,
        )

        val monoParameters = britishMono.parameters as Np3PhotoFilterParameters
        assertEquals(3, monoParameters.contrast)
        assertEquals(-20, monoParameters.highlights)
        assertEquals(31, monoParameters.shadows)
        assertEquals(-34, monoParameters.whites)
        assertEquals(-10, monoParameters.blacks)
        assertEquals(-98, monoParameters.saturation)
        assertEquals(null, monoParameters.toneCurve)

        val cinemaParameters = cinemaBlue.parameters as Np3PhotoFilterParameters
        assertEquals(-5, cinemaParameters.saturation)
        assertEquals(78, cinemaParameters.colorBands[4].chroma)
        assertEquals(100, cinemaParameters.colorBands[5].chroma)
        assertEquals(
            "4700e2c82549d7c475119be74539f2d0594484422fb37afe6f789219b2f5e5d3",
            toneCurveSha256(requireNotNull(cinemaParameters.toneCurve)),
        )

        val portraitParameters = softPortrait.parameters as Np3PhotoFilterParameters
        assertEquals(11, portraitParameters.colorBands[0].hue)
        assertEquals(-16, portraitParameters.colorBands[5].hue)
        assertEquals(11, portraitParameters.colorBands[5].brightness)
        assertEquals(
            "3e2a4eb44786f539f4ef14d0db034d98b15e902c25f7917b35586bfd232c881b",
            toneCurveSha256(requireNotNull(portraitParameters.toneCurve)),
        )
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
