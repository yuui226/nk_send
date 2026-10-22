package com.ztransfer.frame

import com.ztransfer.filter.NcpPhotoFilterParameters
import com.ztransfer.filter.PhotoFilterPreset
import com.ztransfer.filter.PhotoFilterSelection
import com.ztransfer.grain.PhotoGrainSettings
import com.ztransfer.grain.PhotoGrainStyle
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PhotoFramePlaceIdentityTest {
    private val sourceName = "DSC_9415.JPG"
    private val preset = PhotoFramePreset.FROSTED
    private val watermark = PhotoFrameWatermark(enabled = false)
    private val settings = defaultPhotoFrameMetadataSettings(preset)
        .copy(showCity = true, showRegion = true)
    private val place = FramePlace("杭州市", "西湖区")

    @Test
    fun repeatedCompleteOrMissingPlacesSkipForEveryFrame() {
        for (frame in PhotoFramePreset.entries) {
            val options = defaultPhotoFrameMetadataSettings(frame)
                .copy(showCity = true, showRegion = true)
            for (savedPlace in listOf(place, FramePlace("杭州市", null), null)) {
                val identity = photoFrameOutputIdentity(sourceName, frame, watermark,
                    metadataSettings = options, renderedPlace = savedPlace)
                val name = photoFrameOutputName(sourceName, frame, watermark,
                    metadataSettings = options)
                // Exercise the same lookup used by the actual destination, not just hashes.
                repeat(2) {
                    assertTrue("$frame / $savedPlace", hasMatchingPhotoFrameOutput(
                        occupiedNames = setOf(name), sourceName = sourceName,
                        preset = frame, watermark = watermark, metadataSettings = options,
                        renderedPlace = savedPlace,
                    ) { candidate -> identity.takeIf { candidate == name } })
                }
            }
        }
    }

    @Test
    fun fillingMissingPlacesOrChangingSelectedPlaceRequiresANewImage() {
        val places = listOf<FramePlace?>(null, FramePlace("杭州市", null), place,
            FramePlace("杭州市", "上城区"), FramePlace("宁波市", "西湖区"))
        for (savedPlace in places) {
            val saved = identity(savedPlace)
            for (requestedPlace in places) {
                assertEquals("$savedPlace -> $requestedPlace", savedPlace == requestedPlace,
                    matches(saved, requestedPlace))
            }
        }
    }

    @Test
    fun emptyAndWhitespacePlacesHaveOneStableIdentity() {
        val missing = identity(null)
        for (empty in listOf(FramePlace(null, null), FramePlace("", ""),
            FramePlace(" \t ", "\n"))) {
            assertEquals(missing, identity(empty))
            assertTrue(matches(missing, empty))
        }
        assertEquals(identity(place), identity(FramePlace(" 杭州市 ", "\t西湖区\n")))
        assertNotEquals(identity(FramePlace("AB", "C")), identity(FramePlace("A", "BC")))
    }

    @Test
    fun unselectedPlaceFieldsDoNotCauseNewOutputs() {
        val cityOnly = settings.copy(showRegion = false)
        val regionOnly = settings.copy(showCity = false)
        assertEquals(identity(place, cityOnly), identity(FramePlace("杭州市", "上城区"), cityOnly))
        assertEquals(identity(place, cityOnly), identity(FramePlace("杭州市", null), cityOnly))
        assertEquals(identity(place, regionOnly), identity(FramePlace("宁波市", "西湖区"), regionOnly))
        assertEquals(identity(place, regionOnly), identity(FramePlace(null, "西湖区"), regionOnly))
        assertTrue(matches(identity(place, cityOnly), FramePlace("杭州市", null), cityOnly))
        assertTrue(matches(identity(place, regionOnly), FramePlace(null, "西湖区"), regionOnly))
        assertFalse(matches(identity(place), place, cityOnly))
        assertFalse(matches(identity(place), place, regionOnly))
    }

    @Test
    fun oldLongNamesAndOldShortIdentitiesCannotClaimToContainThePlace() {
        val legacyName = legacyPhotoFrameOutputName(sourceName, preset, watermark,
            metadataSettings = settings)
        // This was the exact short-JPEG identity contract before rendered places were recorded.
        val legacyIdentity = oldIdentity(legacyName)
        for (requestedPlace in listOf(place, null)) {
            assertNotEquals(legacyIdentity, identity(requestedPlace))
            for (name in listOf(legacyName, legacyName.removeSuffix(".jpg") + " (2).jpg")) {
                assertFalse(hasMatchingPhotoFrameOutput(setOf(name), sourceName, preset, watermark,
                    metadataSettings = settings, renderedPlace = requestedPlace,
                ) { legacyIdentity })
                assertFalse(isPhotoFrameOutputFor(name, sourceName, preset, watermark,
                    metadataSettings = settings, identity = legacyIdentity,
                    renderedPlace = requestedPlace))
            }
            assertFalse(matches(legacyIdentity, requestedPlace))
            assertFalse(isPhotoFrameOutputFor("DSC_9415_f_2.jpg", sourceName, preset, watermark,
                metadataSettings = settings, identity = null, renderedPlace = requestedPlace))
        }
    }

    @Test
    fun withoutPlaceFieldsOrWithoutBorderExistingIdentitiesRemainCompatible() {
        for (frame in PhotoFramePreset.entries) {
            val defaults = defaultPhotoFrameMetadataSettings(frame)
            for (border in listOf(true, false)) {
                val options = if (border) defaults else defaults.copy(showCity = true, showRegion = true)
                val oldName = legacyPhotoFrameOutputName(sourceName, frame, watermark,
                    borderEnabled = border, metadataSettings = options)
                val expected = oldIdentity(oldName)
                assertEquals(expected, photoFrameOutputIdentity(sourceName, frame, watermark,
                    borderEnabled = border, metadataSettings = options, renderedPlace = place))
                assertTrue(hasMatchingPhotoFrameOutput(setOf(oldName), sourceName, frame, watermark,
                    borderEnabled = border, metadataSettings = options, renderedPlace = place,
                ) { error("Legacy names without rendered place fields need no metadata read") })
            }
        }
    }

    @Test
    fun numberedJpegsStillMatchAfterRebuildingTheFileIndex() {
        val savedIdentity = identity(place)
        // Simulate a fresh directory scan: only names and JPEG bytes survive, no in-memory
        // generation record. Both supported numbering conventions must find the same recipe.
        for (name in listOf("dsc_9415_f (12).JPG", "DSC_9415_f_12.jpg")) {
            val files = mapOf(
                "another_f.jpg" to jpeg(identity(null)),
                "DSC_9415_f.jpg" to jpeg(identity(FramePlace("杭州市", "上城区"))),
                name to jpeg(savedIdentity),
            )
            val readNames = mutableListOf<String>()
            val found = hasMatchingPhotoFrameOutput(files.keys.toSet(), sourceName.lowercase(Locale.ROOT),
                preset, watermark, metadataSettings = settings, renderedPlace = place,
            ) { candidate ->
                readNames += candidate
                files[candidate]?.inputStream()?.use(PhotoEffectIdentityJpeg::read)
            }
            assertTrue(found)
            assertTrue(name in readNames)
            assertFalse("Unrelated source images must not be opened", "another_f.jpg" in readNames)
        }
    }

    @Test
    fun samePlaceDoesNotHideFilterOrGrainChanges() {
        val filter = PhotoFilterSelection(PhotoFilterPreset("place-test", "Place test",
            NcpPhotoFilterParameters(0, 0, IntArray(257) { (it * 0x7fff) / 256 })), 72)
        val grain = PhotoGrainSettings(40, enabled = true, style = PhotoGrainStyle.MEDIUM)
        val savedName = "DSC_9415_f_e_g (3).jpg"
        val savedIdentity = photoFrameOutputIdentity(sourceName, preset, watermark,
            metadataSettings = settings, filter = filter, grain = grain, renderedPlace = place)
        fun matchesRecipe(nextFilter: PhotoFilterSelection? = filter,
            nextGrain: PhotoGrainSettings = grain, nextPlace: FramePlace? = place): Boolean =
            hasMatchingPhotoFrameOutput(setOf(savedName), sourceName, preset, watermark,
                metadataSettings = settings, filter = nextFilter, grain = nextGrain,
                renderedPlace = nextPlace,
            ) { savedIdentity }
        assertTrue(matchesRecipe())
        assertFalse(matchesRecipe(nextFilter = filter.copy(intensityPercent = 74)))
        assertFalse(matchesRecipe(nextFilter = filter.copy(preset = filter.preset.copy(id = "other"))))
        assertFalse(matchesRecipe(nextFilter = null))
        assertFalse(matchesRecipe(nextGrain = grain.copy(intensityPercent = 41)))
        assertFalse(matchesRecipe(nextGrain = grain.copy(style = PhotoGrainStyle.COARSE)))
        assertFalse(matchesRecipe(nextGrain = PhotoGrainSettings.OFF))
        assertFalse(matchesRecipe(nextPlace = null))
        assertTrue(isPhotoFrameOutputFor(savedName, sourceName, preset, watermark,
            metadataSettings = settings, filter = filter, identity = savedIdentity,
            grain = grain, renderedPlace = place))
    }

    @Test
    fun blockedPlaceSnapshotDropsOnlyPlaceTextAndKeepsCameraMetadata() {
        val source = PhotoFrameMetadata("Nikon", "Z 30", "f/2.8", "1/125", "400", "50mm",
            lensModel = "NIKKOR Z", dateTime = "2026:10:22 12:00:00",
            latitude = 30.25, longitude = 120.15, altitudeMeters = 520.0,
            address = "Historical full address", city = place.city, region = place.region,
            brandStyle = PhotoFrameBrandStyle.LOGO)
        assertEquals(source, source.withAllowedFramePlace(true))
        val blocked = source.withAllowedFramePlace(false)
        assertEquals(source.copy(city = null, region = null, address = null), blocked)
        assertEquals(blocked, blocked.withAllowedFramePlace(false))
        assertEquals(identity(null), identity(FramePlace(blocked.city, blocked.region)))
    }

    private fun identity(renderedPlace: FramePlace?, options: PhotoFrameMetadataSettings = settings) =
        photoFrameOutputIdentity(sourceName, preset, watermark,
            metadataSettings = options, renderedPlace = renderedPlace)

    private fun matches(savedIdentity: String, renderedPlace: FramePlace?,
        options: PhotoFrameMetadataSettings = settings): Boolean =
        hasMatchingPhotoFrameOutput(setOf("DSC_9415_f.jpg"), sourceName, preset, watermark,
            metadataSettings = options, renderedPlace = renderedPlace,
        ) { savedIdentity }

    private fun oldIdentity(name: String) = MessageDigest.getInstance("SHA-256")
        .digest(name.lowercase(Locale.ROOT).toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(Locale.ROOT, it.toInt() and 0xff) }

    private fun jpeg(identity: String): ByteArray = ByteArrayOutputStream().also { output ->
        PhotoEffectIdentityJpeg.outputStream(output, identity).use {
            // Header fixture: SOI, small APP0, SOS and EOI. Pixel decoding is not involved in
            // destination lookups, which must read only the identity from JPEG metadata.
            it.write(byteArrayOf(0xff.toByte(), 0xd8.toByte(), 0xff.toByte(), 0xe0.toByte(),
                0, 4, 0, 0, 0xff.toByte(), 0xda.toByte(), 0, 2, 0xff.toByte(), 0xd9.toByte()))
        }
    }.toByteArray()
}
