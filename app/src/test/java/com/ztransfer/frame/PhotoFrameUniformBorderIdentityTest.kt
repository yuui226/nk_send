package com.ztransfer.frame

import com.ztransfer.filter.NcpPhotoFilterParameters
import com.ztransfer.filter.PhotoFilterPreset
import com.ztransfer.filter.PhotoFilterSelection
import com.ztransfer.grain.PhotoGrainSettings
import com.ztransfer.grain.PhotoGrainStyle
import java.security.MessageDigest
import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PhotoFrameUniformBorderIdentityTest {
    private val noWatermark = PhotoFrameWatermark(enabled = false)
    private val frameWatermark = PhotoFrameWatermark(
        text = "Studio",
        position = PhotoFrameWatermarkPosition.CENTER,
    )
    private val noInformation = PhotoFrameMetadataSettings(
        showDate = false,
        showTime = false,
        showFocalLength = false,
        showExposure = false,
        showBrand = false,
        showModel = false,
    )
    private val supported = setOf(
        PhotoFramePreset.MIST,
        PhotoFramePreset.CINEMA,
        PhotoFramePreset.MINIMAL,
        PhotoFramePreset.FROSTED,
        PhotoFramePreset.BRAND_GALLERY,
        PhotoFramePreset.CLASSIC_SIGNATURE,
    )

    @Test
    fun oldUnevenOutputsCannotSkipNewUniformBorders() {
        supported.forEach { preset ->
            val oldName = oldEmptyNames.getValue(preset)
            val oldIdentity = oldIdentity(oldName)
            assertNotEquals(preset.name, oldName, legacyPhotoFrameOutputName(
                "DSC.JPG", preset, noWatermark, metadataSettings = noInformation,
            ))
            assertNotEquals(preset.name, oldIdentity, photoFrameOutputIdentity(
                "DSC.JPG", preset, noWatermark, metadataSettings = noInformation,
            ))
            listOf(oldName, oldName.removeSuffix(".jpg") + " (2).jpg").forEach { name ->
                assertFalse("Old long name: $preset / $name", isPhotoFrameOutputFor(
                    name, "DSC.JPG", preset, noWatermark, metadataSettings = noInformation,
                ))
            }
            listOf("DSC_f.jpg", "dsc_f (2).JPG").forEach { name ->
                assertFalse("Old short name: $preset / $name", isPhotoFrameOutputFor(
                    name, "DSC.JPG", preset, noWatermark,
                    metadataSettings = noInformation, identity = oldIdentity,
                ))
            }
        }
    }

    @Test
    fun repeatedUniformOutputsStillDeduplicateAndWidthChangesDoNot() {
        supported.forEach { preset ->
            val identities = listOf(60, 100, 200).associateWith { width ->
                val settings = noInformation.copy(widthPercent = width)
                val identity = photoFrameOutputIdentity(
                    "DSC.JPG", preset, noWatermark, metadataSettings = settings,
                )
                assertEquals(preset.name, identity, photoFrameOutputIdentity(
                    "dsc.jpg", preset, noWatermark, metadataSettings = settings,
                ))
                assertEquals("DSC_f.jpg", photoFrameOutputName(
                    "DSC.JPG", preset, noWatermark, metadataSettings = settings,
                ))
                assertTrue("Same width must skip: $preset / $width", isPhotoFrameOutputFor(
                    "DSC_f (3).jpg", "DSC.JPG", preset, noWatermark,
                    metadataSettings = settings, identity = identity,
                ))
                identity
            }
            assertEquals(preset.name, 3, identities.values.toSet().size)
            identities.forEach { (savedWidth, savedIdentity) ->
                identities.keys.forEach { requestedWidth ->
                    assertEquals("$preset: $savedWidth -> $requestedWidth", savedWidth == requestedWidth,
                        isPhotoFrameOutputFor(
                            "DSC_f.jpg", "DSC.JPG", preset, noWatermark,
                            metadataSettings = noInformation.copy(widthPercent = requestedWidth),
                            identity = savedIdentity,
                        ))
                }
            }
            // Visible names keep the existing collision numbering across old and new layouts.
            assertEquals("DSC_f (2).jpg", uniqueName("DSC_f.jpg", setOf("DSC_f.jpg", "DSC_f (1).jpg")))
        }
    }

    @Test
    fun restoringInformationKeepsThePreviousLayoutIdentityAndDeduplication() {
        val settings = noInformation.copy(showBrand = true)
        oldBrandOnlyNames.forEach { (preset, oldName) ->
            assertUnchanged(oldName, preset, noWatermark, settings)
        }
    }

    @Test
    fun restoringAFrameWatermarkKeepsThePreviousLayoutIdentityAndDeduplication() {
        // BRAND_INSET always places its watermark inside the photo, including CENTER.
        // CLASSIC_SIGNATURE's old AUTO/CENTER alias is covered by the position regression test.
        oldFrameWatermarkNames.forEach { (preset, oldName) ->
            assertUnchanged(oldName, preset, frameWatermark, noInformation)
        }
    }

    @Test
    fun brandGalleryPhotoInformationRejectsOldBottomBandsButStillDeduplicatesTheNewLayout() {
        val preset = PhotoFramePreset.BRAND_GALLERY
        val settings = brandGalleryPhotoInformation()
        // Frozen from the previously compiled implementation: all photo information on,
        // brand/model off. It formerly kept the larger information band.
        val oldName = "DSC_frame_brand_gallery_w42c915e03ad9.jpg"
        val previousIdentity = oldIdentity(oldName)
        val currentIdentity = photoFrameOutputIdentity(
            "DSC.JPG", preset, noWatermark, metadataSettings = settings,
        )
        assertTrue(usesUniformPhotoFrameBorder(preset, settings, noWatermark))
        assertNotEquals(oldName, legacyPhotoFrameOutputName(
            "DSC.JPG", preset, noWatermark, metadataSettings = settings,
        ))
        assertNotEquals(previousIdentity, currentIdentity)
        assertFalse(isPhotoFrameOutputFor(
            oldName, "DSC.JPG", preset, noWatermark, metadataSettings = settings,
        ))
        assertFalse(isPhotoFrameOutputFor(
            "DSC_f (2).jpg", "DSC.JPG", preset, noWatermark,
            metadataSettings = settings, identity = previousIdentity,
        ))
        assertTrue(isPhotoFrameOutputFor(
            "DSC_f (2).jpg", "dsc.jpg", preset, noWatermark,
            metadataSettings = settings, identity = currentIdentity,
        ))
        val withoutEachPhotoField = listOf(
            settings.copy(showDate = false),
            settings.copy(showTime = false),
            settings.copy(showFocalLength = false),
            settings.copy(showExposure = false),
            settings.copy(showLensModel = false),
            settings.copy(showCoordinates = false),
            settings.copy(showAltitude = false),
            settings.copy(showCity = false),
            settings.copy(showRegion = false),
        )
        for (changed in withoutEachPhotoField) {
            assertTrue(usesUniformPhotoFrameBorder(preset, changed, noWatermark))
            assertFalse("Photo text changes must not reuse the old image: $changed",
                isPhotoFrameOutputFor("DSC_f.jpg", "DSC.JPG", preset, noWatermark,
                    metadataSettings = changed, identity = currentIdentity))
        }
    }

    @Test
    fun brandGalleryRestoringBandContentKeepsLayoutIdentityButRequiresKnownRenderedPlace() {
        val preset = PhotoFramePreset.BRAND_GALLERY
        val settings = brandGalleryPhotoInformation()
        val unchangedLayouts = listOf(
            Triple("DSC_frame_brand_gallery_w75947c56c87a.jpg",
                noWatermark, settings.copy(showBrand = true)),
            Triple("DSC_frame_brand_gallery_w2f2aeb105db8.jpg",
                noWatermark, settings.copy(showModel = true)),
            Triple("DSC_frame_brand_gallery_w071486100057.jpg", frameWatermark, settings),
        )
        for ((oldName, watermark, restoredSettings) in unchangedLayouts) {
            // Restoring band content keeps the frozen layout recipe. Its old output identity,
            // however, cannot tell whether the enabled city/region were actually rendered.
            assertEquals(oldName, legacyPhotoFrameOutputName(
                "DSC.JPG", preset, watermark, metadataSettings = restoredSettings,
            ))
            for (place in listOf(null, FramePlace("Shanghai", "Huangpu"))) {
                val currentIdentity = photoFrameOutputIdentity(
                    "DSC.JPG", preset, watermark, metadataSettings = restoredSettings,
                    renderedPlace = place,
                )
                assertNotEquals(oldIdentity(oldName), currentIdentity)
                assertFalse("Legacy name does not prove the rendered place", isPhotoFrameOutputFor(
                    oldName, "DSC.JPG", preset, watermark, metadataSettings = restoredSettings,
                    renderedPlace = place,
                ))
                assertFalse("Legacy short identity has no rendered place", isPhotoFrameOutputFor(
                    "DSC_f (2).jpg", "DSC.JPG", preset, watermark,
                    metadataSettings = restoredSettings, identity = oldIdentity(oldName),
                    renderedPlace = place,
                ))
                assertTrue("Same layout and actual place must still skip", isPhotoFrameOutputFor(
                    "DSC_f (2).jpg", "DSC.JPG", preset, watermark,
                    metadataSettings = restoredSettings, identity = currentIdentity,
                    renderedPlace = place,
                ))
            }
        }
    }

    @Test
    fun excludedFramesRetainTheirEmptyLayoutIdentityAndDeduplication() {
        val excluded = oldEmptyNames.filterKeys { it !in supported }
        assertEquals(9, excluded.size)
        excluded.forEach { (preset, oldName) ->
            assertUnchanged(oldName, preset, noWatermark, noInformation)
        }
    }

    @Test
    fun disablingTheBorderKeepsWatermarkOnlyIdentityForEveryPreset() {
        assertEquals(PhotoFramePreset.entries.toSet(), oldWatermarkOnlyNames.keys)
        oldWatermarkOnlyNames.forEach { (preset, oldName) ->
            assertUnchanged(oldName, preset, frameWatermark, noInformation, borderEnabled = false)
            assertEquals(preset.name, oldIdentity(oldName), photoFrameOutputIdentity(
                "DSC.JPG", preset, frameWatermark, borderEnabled = false,
                metadataSettings = noInformation.copy(widthPercent = 200),
            ))
        }
    }

    @Test
    fun brandInsetKeepsItsAlreadyUniformLayoutIdentityAcrossWidthsAndWatermarks() {
        val watermarks = mapOf(
            "none" to noWatermark,
            "text-auto" to PhotoFrameWatermark(text = "Studio"),
            "image-photo" to PhotoFrameWatermark(
                content = PhotoFrameWatermarkContent.IMAGE,
                imageHash = "a".repeat(64),
                position = PhotoFrameWatermarkPosition.PHOTO_TOP_LEFT,
            ),
        )
        oldBrandInsetWidthNames.forEach { (width, names) ->
            names.forEach { (watermarkKind, oldName) ->
                assertUnchanged(
                    oldName, PhotoFramePreset.BRAND_INSET, watermarks.getValue(watermarkKind),
                    noInformation.copy(widthPercent = width),
                )
            }
        }
    }

    @Test
    fun uniformBordersComposeWithCropFilterAndGrainWithoutWeakeningDeduplication() {
        val sourceName = "DSC_c (1).JPG"
        val filter = PhotoFilterSelection(
            preset = PhotoFilterPreset(
                id = "0123456789abcdef",
                name = "Test",
                parameters = NcpPhotoFilterParameters(
                    saturationStep = 0,
                    hueStep = 0,
                    toneCurve = IntArray(257) { index -> (index * 0x7fff) / 256 },
                ),
            ),
            intensityPercent = 72,
        )
        val grain = PhotoGrainSettings(40, enabled = true, style = PhotoGrainStyle.MEDIUM)
        supported.forEach { preset ->
            val preferred = photoFrameOutputName(
                sourceName, preset, noWatermark, metadataSettings = noInformation,
                filter = filter, grain = grain,
            )
            val identity = photoFrameOutputIdentity(
                sourceName, preset, noWatermark, metadataSettings = noInformation,
                filter = filter, grain = grain,
            )
            assertEquals("DSC_c (1)_f_e_g.jpg", preferred)
            val savedName = "DSC_c (1)_f_e_g (2).jpg"
            assertTrue("Same complete recipe: $preset", isPhotoFrameOutputFor(
                savedName, sourceName.lowercase(Locale.ROOT), preset, noWatermark,
                metadataSettings = noInformation, filter = filter, identity = identity, grain = grain,
            ))
            assertFalse("Old uneven combined output: $preset", isPhotoFrameOutputFor(
                savedName, sourceName, preset, noWatermark, metadataSettings = noInformation,
                filter = filter, identity = oldCombinedIdentities.getValue(preset), grain = grain,
            ))

            fun assertChangedRecipeDoesNotMatch(
                label: String,
                changedSource: String = sourceName,
                changedSettings: PhotoFrameMetadataSettings = noInformation,
                changedFilter: PhotoFilterSelection? = filter,
                changedGrain: PhotoGrainSettings = grain,
            ) {
                assertNotEquals("$preset: $label identity", identity, photoFrameOutputIdentity(
                    changedSource, preset, noWatermark, metadataSettings = changedSettings,
                    filter = changedFilter, grain = changedGrain,
                ))
                assertFalse("$preset: $label must not reuse the saved output", isPhotoFrameOutputFor(
                    savedName, changedSource, preset, noWatermark, metadataSettings = changedSettings,
                    filter = changedFilter, identity = identity, grain = changedGrain,
                ))
            }
            assertChangedRecipeDoesNotMatch("frame width", changedSettings = noInformation.copy(widthPercent = 145))
            assertChangedRecipeDoesNotMatch("restored information", changedSettings = noInformation.copy(showBrand = true))
            assertChangedRecipeDoesNotMatch("filter amount", changedFilter = filter.copy(intensityPercent = 74))
            assertChangedRecipeDoesNotMatch("filter preset", changedFilter = filter.copy(
                preset = filter.preset.copy(id = "fedcba9876543210")))
            assertChangedRecipeDoesNotMatch("filter disabled", changedFilter = null)
            assertChangedRecipeDoesNotMatch("grain amount", changedGrain = grain.copy(intensityPercent = 41))
            assertChangedRecipeDoesNotMatch("grain style", changedGrain = grain.copy(style = PhotoGrainStyle.COARSE))
            assertChangedRecipeDoesNotMatch("grain disabled", changedGrain = PhotoGrainSettings.OFF)
            assertChangedRecipeDoesNotMatch("another crop", changedSource = "DSC_c (2).JPG")
            assertChangedRecipeDoesNotMatch("uncropped source", changedSource = "DSC.JPG")
            // The same visible stem has a different grain seed for a different source extension.
            assertChangedRecipeDoesNotMatch("source seed", changedSource = "DSC_c (1).JPEG")
        }
    }

    private fun brandGalleryPhotoInformation() = noInformation.copy(
        showDate = true,
        showTime = true,
        showFocalLength = true,
        showExposure = true,
        showLensModel = true,
        showCoordinates = true,
        showAltitude = true,
        showCity = true,
        showRegion = true,
    )

    private fun assertUnchanged(
        oldName: String,
        preset: PhotoFramePreset,
        watermark: PhotoFrameWatermark,
        settings: PhotoFrameMetadataSettings,
        borderEnabled: Boolean = true,
    ) {
        val identity = oldIdentity(oldName)
        assertEquals(preset.name, oldName, legacyPhotoFrameOutputName(
            "DSC.JPG", preset, watermark, borderEnabled, settings,
        ))
        assertEquals(preset.name, identity, photoFrameOutputIdentity(
            "DSC.JPG", preset, watermark, borderEnabled, settings,
        ))
        assertTrue("Old long output must still match: $preset", isPhotoFrameOutputFor(
            oldName, "DSC.JPG", preset, watermark, borderEnabled, settings,
        ))
        assertTrue("Old short output must still match: $preset", isPhotoFrameOutputFor(
            if (borderEnabled) "DSC_f (2).jpg" else "DSC_w (2).jpg",
            "DSC.JPG", preset, watermark, borderEnabled, settings, identity = identity,
        ))
    }

    /** The pre-change short identity was SHA-256 of the case-normalized legacy filename. */
    private fun oldIdentity(oldName: String): String = MessageDigest.getInstance("SHA-256")
        .digest(oldName.lowercase(Locale.ROOT).toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(Locale.ROOT, it.toInt() and 0xff) }

    companion object {
        // Frozen fixtures from 8f64f803 (measured-layout-v=6), independently calculated from
        // the old serialization. Do not regenerate these using the production fingerprint:
        // they prove that pre-upgrade JPEGs are reused only when their layout is unchanged.
        private val oldEmptyNames = mapOf(
            PhotoFramePreset.MIST to "DSC_frame_mist_w98254e54cd42.jpg",
            PhotoFramePreset.CINEMA to "DSC_frame_dark_w25cdc577c6c3.jpg",
            PhotoFramePreset.MINIMAL to "DSC_frame_clean_w8bf9b7187989.jpg",
            PhotoFramePreset.FROSTED to "DSC_frame_glass_w26ce5566474d.jpg",
            PhotoFramePreset.PLAQUE to "DSC_frame_plaque_w13c6c8f01b6e.jpg",
            PhotoFramePreset.IMMERSIVE to "DSC_frame_immersive_w664b73e7fdad.jpg",
            PhotoFramePreset.BRAND_INSET to "DSC_frame_brand_inset_wf5abb1d01c0d.jpg",
            PhotoFramePreset.BRAND_GALLERY to "DSC_frame_brand_gallery_w55c83a3b2c31.jpg",
            PhotoFramePreset.CLASSIC_SIGNATURE to "DSC_frame_classic_signature_we76696d45521.jpg",
            PhotoFramePreset.GALLERY_MAT to "DSC_frame_gallery_mat_w6166c0f684de.jpg",
            PhotoFramePreset.COLOR_ARCHIVE to "DSC_frame_color_archive_w344dee657c94.jpg",
            PhotoFramePreset.FILM_GALLERY to "DSC_frame_film_gallery_w974937f2f840.jpg",
            PhotoFramePreset.FILM_EDGE to "DSC_frame_film_edge_w6166c0f684de.jpg",
            PhotoFramePreset.FILM_NEGATIVE to "DSC_frame_film_negative_waed74e7a2df8.jpg",
            PhotoFramePreset.PARAMETER_POSTER to "DSC_frame_parameter_poster_wbfd283642864.jpg",
        )
        private val oldBrandOnlyNames = mapOf(
            PhotoFramePreset.MIST to "DSC_frame_mist_w8aa183d7375d.jpg",
            PhotoFramePreset.CINEMA to "DSC_frame_dark_wc2def882c427.jpg",
            PhotoFramePreset.MINIMAL to "DSC_frame_clean_w42f831d6f3fe.jpg",
            PhotoFramePreset.FROSTED to "DSC_frame_glass_w1c3b72846275.jpg",
            PhotoFramePreset.BRAND_INSET to "DSC_frame_brand_inset_we29b77e1423e.jpg",
            PhotoFramePreset.BRAND_GALLERY to "DSC_frame_brand_gallery_w26b81531d225.jpg",
            PhotoFramePreset.CLASSIC_SIGNATURE to "DSC_frame_classic_signature_wbf723a13584e.jpg",
        )
        private val oldFrameWatermarkNames = mapOf(
            PhotoFramePreset.MIST to "DSC_frame_mist_w2a3cd55a4da8.jpg",
            PhotoFramePreset.CINEMA to "DSC_frame_dark_wf0bb8de08e7a.jpg",
            PhotoFramePreset.MINIMAL to "DSC_frame_clean_wea4a2a7c0e4f.jpg",
            PhotoFramePreset.FROSTED to "DSC_frame_glass_w0008e5235e12.jpg",
            PhotoFramePreset.BRAND_GALLERY to "DSC_frame_brand_gallery_w47f73446baa0.jpg",
        )
        private val oldWatermarkOnlyNames = mapOf(
            PhotoFramePreset.MIST to "DSC_watermark_wcac41826c229.jpg",
            PhotoFramePreset.CINEMA to "DSC_watermark_wcac41826c229.jpg",
            PhotoFramePreset.MINIMAL to "DSC_watermark_wcac41826c229.jpg",
            PhotoFramePreset.FROSTED to "DSC_watermark_w7c5bb30a0cdb.jpg",
            PhotoFramePreset.PLAQUE to "DSC_watermark_wcac41826c229.jpg",
            PhotoFramePreset.IMMERSIVE to "DSC_watermark_w2a2176c48294.jpg",
            PhotoFramePreset.BRAND_INSET to "DSC_watermark_w5c5ee8afec58.jpg",
            PhotoFramePreset.BRAND_GALLERY to "DSC_watermark_w5c5ee8afec58.jpg",
            PhotoFramePreset.CLASSIC_SIGNATURE to "DSC_watermark_wefbccaff3ad8.jpg",
            PhotoFramePreset.GALLERY_MAT to "DSC_watermark_wefbccaff3ad8.jpg",
            PhotoFramePreset.COLOR_ARCHIVE to "DSC_watermark_w7d3dd13af2f2.jpg",
            PhotoFramePreset.FILM_GALLERY to "DSC_watermark_w02dc0beaed4a.jpg",
            PhotoFramePreset.FILM_EDGE to "DSC_watermark_wefbccaff3ad8.jpg",
            PhotoFramePreset.FILM_NEGATIVE to "DSC_watermark_w783b32c45970.jpg",
            PhotoFramePreset.PARAMETER_POSTER to "DSC_watermark_wefbccaff3ad8.jpg",
        )
        private val oldBrandInsetWidthNames = mapOf(
            60 to mapOf(
                "none" to "DSC_frame_brand_inset_w98fc2bfe1e19.jpg",
                "text-auto" to "DSC_frame_brand_inset_wc9d87fef418b.jpg",
                "image-photo" to "DSC_frame_brand_inset_wf9ae748b7162.jpg",
            ),
            145 to mapOf(
                "none" to "DSC_frame_brand_inset_w78dec7cf780d.jpg",
                "text-auto" to "DSC_frame_brand_inset_we3deefd88209.jpg",
                "image-photo" to "DSC_frame_brand_inset_wbcd7fa2f9671.jpg",
            ),
            200 to mapOf(
                "none" to "DSC_frame_brand_inset_w4a586485c8a1.jpg",
                "text-auto" to "DSC_frame_brand_inset_wc7f839244e12.jpg",
                "image-photo" to "DSC_frame_brand_inset_w3fd967aa2314.jpg",
            ),
        )
        // Same old empty-border fixtures, source "DSC_c (1).JPG", filter 0123456789abcdef
        // at 72%, medium grain at 40%. Freeze the old composed identity, including its seed.
        private val oldCombinedIdentities = mapOf(
            PhotoFramePreset.MIST to "aa6fb7df32b78aa488d38bf1c730ba6ad496e5dffd625a972dc0572376e758ba",
            PhotoFramePreset.CINEMA to "edd68a646f6a53c3aae51bf71d1f6f4932b9d83e8985a436af3930ef01f05c18",
            PhotoFramePreset.MINIMAL to "39eb852b15e50d3b5761e1398fc81c1ca932eb269402197936480f3a212e33c1",
            PhotoFramePreset.FROSTED to "3cdd8b44976ae505f59125c0e9e43898a92a811fa48bf961f0e7d0b34385992c",
            PhotoFramePreset.BRAND_GALLERY to "08a3a572c8eb592908d865c6b38f3203e2561b14f69fab82ec8f8c30da96a2c9",
            PhotoFramePreset.CLASSIC_SIGNATURE to "b2f5ea15ec86537697ef01c400a839c12e74b89e80945b073f830d9a0d932a8e",
        )
    }
}
