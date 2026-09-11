package com.ztransfer.filter

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class BuiltInPhotoFiltersTest {
    @Test
    fun builtInSetContainsFiftyDistinctCuratedNp3Presets() {
        val filters = BuiltInPhotoFilters.all

        assertEquals(50, filters.size)
        assertEquals(
            listOf(
                "Forest Verdure", "Dusk Ember", "Bleached Silver", "Blue Hour",
                "Blue Memory", "British Mono", "Love Glow", "Calm Breeze",
                "Cinema Blue", "Cinematic Dusk", "Clear Portrait", "Cozy Autumn",
                "Dawn Hues", "Darkroom Film", "Fern Shade", "Classic Film",
                "Golden Dusk", "Soft Harmony", "Urban Green", "Matte Blue",
                "Moss Mood", "Green Shadows", "Soft Portrait", "Natural Link",
                "Cyan Negative", "Red Cyan", "Teal Negative", "Lemon Negative",
                "Amber Negative", "Lime Negative", "Pastel Pink", "Rose Vintage",
                "Setouchi Blue", "Sky Mist", "Soft Film", "Soft Glow",
                "Cool Sun Kiss", "Warm Sun Kiss", "Sunset Film", "Sunset Glow",
                "Teal and Orange", "Gentle Clarity", "Turquoise Blue", "Vintage Color",
                "Vintage Vibe", "Vital Film", "Warm Street", "Warm Lowlight",
                "Warm Portrait", "Honey Warm",
            ),
            filters.map { it.name },
        )
        assertEquals(filters.size, filters.map { it.id }.distinct().size)
        assertEquals(
            filters.size,
            filters.mapNotNull { filter -> BuiltInPhotoFilters.catalogKey(filter.id) }
                .distinct()
                .size,
        )
        filters.forEach { filter ->
            assertTrue(filter.id.matches(Regex("[0-9a-f]{64}")))
            assertTrue(
                BuiltInPhotoFilters.catalogKey(filter.id)
                    ?.matches(Regex("[0-9a-f]{64}")) == true,
            )
            assertIs<Np3PhotoFilterParameters>(filter.parameters)
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

        val mono = britishMono.parameters as Np3PhotoFilterParameters
        assertContentEquals(intArrayOf(3, -20, 31, -34, -10, -98), mono.globalControls())
        assertEquals(null, mono.toneCurve)

        val cinema = cinemaBlue.parameters as Np3PhotoFilterParameters
        assertEquals(-5, cinema.saturation)
        assertEquals(78, cinema.colorBands[4].chroma)
        assertEquals(100, cinema.colorBands[5].chroma)
        assertCurveLandmarks(
            expected = intArrayOf(1670, 5822, 18768, 26577, 29298),
            expectedSum = 4_286_416,
            curve = assertNotNull(cinema.toneCurve),
        )

        val portrait = softPortrait.parameters as Np3PhotoFilterParameters
        assertEquals(11, portrait.colorBands[0].hue)
        assertEquals(-16, portrait.colorBands[5].hue)
        assertEquals(11, portrait.colorBands[5].brightness)
        assertCurveLandmarks(
            expected = intArrayOf(1028, 6621, 18243, 29248, 32767),
            expectedSum = 4_571_025,
            curve = assertNotNull(portrait.toneCurve),
        )
    }

    private fun Np3PhotoFilterParameters.globalControls() = intArrayOf(
        contrast,
        highlights,
        shadows,
        whites,
        blacks,
        saturation,
    )

    private fun assertCurveLandmarks(
        expected: IntArray,
        expectedSum: Int,
        curve: IntArray,
    ) {
        assertEquals(PHOTO_FILTER_TONE_CURVE_POINT_COUNT, curve.size)
        assertContentEquals(
            expected,
            intArrayOf(curve[0], curve[64], curve[128], curve[192], curve[256]),
        )
        assertEquals(expectedSum, curve.sum())
    }
}
