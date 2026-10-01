package com.ztransfer.frame

import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.util.Locale

class PhotoFramePlaceTest {
    private val source = PhotoFrameMetadata(null, null, null, null, null, null,
        latitude = 30.25, longitude = 120.15, altitudeMeters = 520.0)
    private val settings = defaultPhotoFrameMetadataSettings(PhotoFramePreset.PLAQUE)
        .copy(showCity = true, showRegion = true, showCoordinates = true, showAltitude = true)

    @Test fun blockedModeNeverCallsBackendAndDropsCachedPlace() = runBlocking {
        val result = resolveFramePlace(source.copy(city = "杭州市", region = "西湖区"), settings, { false }) { _, _ ->
            fail("AP/offline must not invoke geocoder, even with cached data")
            null
        }
        assertNull(result.city)
        assertNull(result.region)
        assertEquals(source.latitude, result.latitude)
        assertEquals(source.altitudeMeters, result.altitudeMeters)
    }

    @Test fun unselectedFieldsAndInvalidCoordinatesNeverQuery() = runBlocking {
        suspend fun check(metadata: PhotoFrameMetadata, options: PhotoFrameMetadataSettings) {
            resolveFramePlace(metadata, options, { true }) { _, _ -> fail("Unexpected lookup"); null }
        }
        check(source, settings.copy(showCity = false, showRegion = false))
        check(source.copy(latitude = null), settings)
        check(source.copy(latitude = Double.NaN), settings)
        check(source.copy(longitude = 181.0), settings)
        check(source.copy(latitude = 0.0, longitude = 0.0), settings)
    }

    @Test fun connectivityLossWhileQueryCompletesDropsResult() = runBlocking {
        var online = true
        val result = resolveFramePlace(source, settings, { online }) { _, _ ->
            online = false
            FramePlace("杭州市", "西湖区")
        }
        assertNull(result.city)
        assertNull(result.region)
    }

    @Test fun missingGeocoderResultIsSilentAndKeepsOtherFields() = runBlocking {
        assertEquals(source, resolveFramePlace(source, settings, { true }) { _, _ -> null })
    }

    @Test fun cityAndDistrictAreIndependentAndPlaceholdersArePreviewOnly() {
        val data = source.copy(city = "杭州市", region = "西湖区")
        assertEquals(listOf("杭州市 · 西湖区", "N 30°15.000', E 120°09.000'  520m"), frameLocationRows(data))
        assertEquals("西湖区", frameLocationRows(data.withPresentation(settings.copy(showCity = false))).first())
        assertEquals("杭州市", frameLocationRows(data.withPresentation(settings.copy(showRegion = false))).first())
        val empty = source.withPresentation(settings, preview = true, previewLocale = Locale.SIMPLIFIED_CHINESE)
        assertEquals("光影市", empty.city)
        assertEquals("蓝调区", empty.region)
        val exported = source.withPresentation(settings)
        assertNull(exported.city)
        assertNull(exported.region)
        assertEquals(listOf("杭州市"), frameLocationRows(data.copy(city = "杭州市", region = "杭州市", latitude = null, altitudeMeters = null)))
    }

    @Test fun municipalitiesAndMissingDistrictDoNotInventStreetData() {
        assertEquals(FramePlace("上海市", "黄浦区"), framePlace(null, "黄浦区", null, "上海市"))
        assertEquals(FramePlace("Paris", null), framePlace("Paris", null, "Paris", "Île-de-France"))
        assertEquals(FramePlace("杭州市", "西湖区"), framePlace("杭州市", "西湖区", "杭州市", "浙江省"))
    }

    @Test fun countiesAndProvincesNeverBecomeCities() {
        assertEquals(FramePlace(null, "桐庐县"), framePlace(null, null, "桐庐县", "浙江省", "CN"))
        assertEquals(FramePlace(null, "桐庐县"), framePlace("桐庐县", null, null, "浙江省", "CN"))
        assertEquals(FramePlace(null, null), framePlace("浙江省", null, null, "浙江省", "CN"))
        assertEquals(FramePlace(null, null), framePlace(null, "广西壮族自治区", null, "广西壮族自治区", "CN"))
        assertEquals(FramePlace(null, "Santa Clara County"), framePlace(null, null, "Santa Clara County", "California", "US"))
        assertEquals(FramePlace(null, "Santa Clara County"), framePlace("Santa Clara County", null, null, "California", "US"))
    }

    @Test fun neighborhoodsAndDevelopmentZonesAreNotDistrictFallbacks() {
        assertEquals(FramePlace("杭州市", null), framePlace("杭州市", "幸福社区", null, "浙江省", "CN"))
        assertEquals(FramePlace("杭州市", "西湖区"), framePlace("杭州市", "幸福社区", "西湖区", "浙江省", "CN"))
        assertEquals(FramePlace("杭州市", null), framePlace("杭州市", "高新区", null, "浙江省", "CN"))
        assertEquals(FramePlace("杭州市", null), framePlace("幸福社区", null, "杭州市", "浙江省", "CN"))
        assertEquals(FramePlace("New York", null), framePlace("New York", "SoHo", null, "New York", "US"))
        assertEquals(FramePlace("San Jose", "Santa Clara County"), framePlace("San Jose", "Downtown", "Santa Clara County", "California", "US"))
    }

    @Test fun municipalitiesDuplicateNamesAndMissingFieldsAreHandled() {
        assertEquals(FramePlace("重慶市", "渝中區"), framePlace(null, "渝中區", null, "重慶市", "CN"))
        assertEquals(FramePlace("Beijing", "Haidian District"), framePlace(null, "Haidian District", null, "Beijing", "CN"))
        assertEquals(FramePlace("上海市", null), framePlace(null, "市辖区", null, "上海市", "CN"))
        assertEquals(FramePlace("Paris", null), framePlace(" Paris ", "Montmartre", "PARIS", "Île-de-France", "FR"))
        assertEquals(FramePlace(null, null), framePlace(" ", null, null, "California", "US"))
        assertEquals(FramePlace("新宿区", null), framePlace("新宿区", null, null, "東京都", "JP"))
    }

    @Test fun equatorAndPrimeMeridianRemainValidThroughoutPresentation() = runBlocking {
        for ((lat, lon) in listOf(0.0 to 30.0, 51.5 to 0.0)) {
            var calls = 0
            val result = resolveFramePlace(source.copy(latitude = lat, longitude = lon), settings, { true }) { _, _ ->
                calls++
                FramePlace("Example city", null)
            }.withPresentation(settings)
            assertEquals(1, calls)
            assertEquals(lat, result.latitude!!, 0.0)
            assertEquals(lon, result.longitude!!, 0.0)
            assertEquals(2, frameLocationRows(result).size)
        }
        assertFalse(validFrameCoordinates(0.0, 0.0))
        assertFalse(validFrameCoordinates(-91.0, 0.0))
        assertFalse(validFrameCoordinates(0.0, Double.POSITIVE_INFINITY))
    }

    @Test fun everyPresetPersistsBothSwitchesAndKeepsOldDefaults() {
        for (preset in PhotoFramePreset.entries) {
            val defaults = defaultPhotoFrameMetadataSettings(preset)
            assertFalse(defaults.showCity)
            assertFalse(defaults.showRegion)
            for (city in listOf(false, true)) for (region in listOf(false, true)) {
                val value = defaults.copy(showCity = city, showRegion = region)
                val restored = resolvedPhotoFrameMetadataSettings(decodePhotoFrameMetadataSettings(
                    encodePhotoFrameMetadataSettings(mapOf(preset to value))), preset)
                assertEquals(value, restored)
            }
        }
        assertFalse(settings.withoutLocationFields().showCity)
        assertFalse(settings.withoutLocationFields().showRegion)
    }
}
