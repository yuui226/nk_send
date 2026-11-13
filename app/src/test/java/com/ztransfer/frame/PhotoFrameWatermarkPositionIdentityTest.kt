package com.ztransfer.frame

import java.security.MessageDigest
import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PhotoFrameWatermarkPositionIdentityTest {
    private val watermark = PhotoFrameWatermark()
    private val positions = listOf(PhotoFrameWatermarkPosition.AUTO, PhotoFrameWatermarkPosition.CENTER)
    private val noInformation = PhotoFrameMetadataSettings(
        showDate = false,
        showTime = false,
        showFocalLength = false,
        showExposure = false,
        showBrand = false,
        showModel = false,
    )

    @Test
    fun distinctPositionsCannotDeduplicateAcrossInformationStates() {
        oldAmbiguousNames.keys.forEach { preset ->
            val states = listOf(
                "default" to defaultPhotoFrameMetadataSettings(preset),
                "off" to noInformation,
                "restored" to noInformation.copy(showBrand = true),
            )
            states.forEach { (state, settings) ->
                val identities = positions.associateWith { position ->
                    photoFrameOutputIdentity("DSC.JPG", preset, watermark.copy(position = position),
                        metadataSettings = settings)
                }
                assertEquals("$preset / $state", 2, identities.values.toSet().size)
                positions.forEach { savedPosition ->
                    val savedWatermark = watermark.copy(position = savedPosition)
                    val savedIdentity = identities.getValue(savedPosition)
                    val savedLongName = legacyPhotoFrameOutputName("DSC.JPG", preset, savedWatermark,
                        metadataSettings = settings)
                    assertEquals("Repeated position: $preset / $state / $savedPosition", savedIdentity,
                        photoFrameOutputIdentity("dsc.jpg", preset, savedWatermark, metadataSettings = settings))
                    positions.forEach { requestedPosition ->
                        val requested = watermark.copy(position = requestedPosition)
                        val label = "$preset / $state: $savedPosition -> $requestedPosition"
                        assertEquals("Short name: $label", savedPosition == requestedPosition,
                            isPhotoFrameOutputFor("DSC_f (2).jpg", "DSC.JPG", preset, requested,
                                metadataSettings = settings, identity = savedIdentity))
                        assertEquals("Long name: $label", savedPosition == requestedPosition,
                            isPhotoFrameOutputFor(savedLongName, "DSC.JPG", preset, requested,
                                metadataSettings = settings))
                    }
                }
            }
        }
    }

    @Test
    fun restoringInformationDoesNotReuseTheHiddenInformationOutput() {
        val restored = noInformation.copy(showBrand = true)
        oldAmbiguousNames.keys.forEach { preset ->
            positions.forEach { position ->
                val selected = watermark.copy(position = position)
                val hiddenIdentity = photoFrameOutputIdentity("DSC.JPG", preset, selected,
                    metadataSettings = noInformation)
                val restoredIdentity = photoFrameOutputIdentity("DSC.JPG", preset, selected,
                    metadataSettings = restored)
                assertNotEquals("$preset / $position", hiddenIdentity, restoredIdentity)
                assertFalse("Restoring information: $preset / $position", isPhotoFrameOutputFor(
                    "DSC_f.jpg", "DSC.JPG", preset, selected,
                    metadataSettings = restored, identity = hiddenIdentity))
                assertFalse("Hiding information: $preset / $position", isPhotoFrameOutputFor(
                    "DSC_f.jpg", "DSC.JPG", preset, selected,
                    metadataSettings = noInformation, identity = restoredIdentity))
                assertTrue("Returning to the saved recipe: $preset / $position", isPhotoFrameOutputFor(
                    "DSC_f.jpg", "DSC.JPG", preset, selected,
                    metadataSettings = noInformation, identity = hiddenIdentity))
            }
        }
    }

    @Test
    fun bothPositionsRejectAmbiguousLegacyLongAndShortNames() {
        oldAmbiguousNames.forEach { (preset, oldName) ->
            val oldIdentity = identityOfLegacyName(oldName)
            positions.forEach { position ->
                val selected = watermark.copy(position = position)
                assertNotEquals("Both choices must be versioned: $preset / $position", oldName,
                    legacyPhotoFrameOutputName("DSC.JPG", preset, selected))
                assertNotEquals("Old shared identity: $preset / $position", oldIdentity,
                    photoFrameOutputIdentity("DSC.JPG", preset, selected))
                listOf(oldName, oldName.removeSuffix(".jpg") + " (2).jpg").forEach { name ->
                    assertFalse("Old long name: $preset / $position / $name", isPhotoFrameOutputFor(
                        name, "DSC.JPG", preset, selected))
                }
                listOf("DSC_f.jpg", "dsc_f (2).JPG").forEach { name ->
                    assertFalse("Old short name: $preset / $position / $name", isPhotoFrameOutputFor(
                        name, "DSC.JPG", preset, selected, identity = oldIdentity))
                }
            }
        }
    }

    @Test
    fun theOtherElevenPresetsKeepTheirPreviousPositionFingerprints() {
        val unchanged = oldFingerprints.filterKeys { it !in oldAmbiguousNames }
        assertEquals(11, unchanged.size)
        unchanged.forEach { (preset, old) ->
            assertEquals("$preset / AUTO", old.auto, photoFrameWatermarkFingerprint(watermark, preset))
            assertEquals("$preset / CENTER", old.center, photoFrameWatermarkFingerprint(
                watermark.copy(position = PhotoFrameWatermarkPosition.CENTER), preset))
        }
    }

    @Test
    fun disablingTheBorderPreservesThePreviousWatermarkOnlyIdentity() {
        oldFingerprints.forEach { (preset, old) ->
            val oldName = "DSC_watermark_w${old.watermarkOnly}.jpg"
            positions.forEach { position ->
                val selected = watermark.copy(position = position)
                // Both requested positions become PHOTO_BOTTOM_CENTER without a border.
                val settings = noInformation.copy(widthPercent = 145, showBrand = true)
                assertEquals("$preset / $position", oldName, legacyPhotoFrameOutputName(
                    "DSC.JPG", preset, selected, borderEnabled = false, metadataSettings = settings))
                assertEquals("$preset / $position", identityOfLegacyName(oldName), photoFrameOutputIdentity(
                    "DSC.JPG", preset, selected, borderEnabled = false, metadataSettings = settings))
                assertTrue("$preset / $position", isPhotoFrameOutputFor(
                    "DSC_w (2).jpg", "DSC.JPG", preset, selected, borderEnabled = false,
                    metadataSettings = settings, identity = identityOfLegacyName(oldName)))
            }
        }
    }

    @Test
    fun disabledWatermarksKeepTheirPreviousFingerprint() {
        oldFingerprints.forEach { (preset, old) ->
            positions.forEach { position ->
                assertEquals("$preset / $position", old.disabled, photoFrameWatermarkFingerprint(
                    watermark.copy(enabled = false, position = position), preset))
            }
        }
    }

    @Test
    fun imageWatermarksKeepTheirPreviousFingerprint() {
        val image = watermark.copy(content = PhotoFrameWatermarkContent.IMAGE, imageHash = "a".repeat(64))
        oldFingerprints.forEach { (preset, old) ->
            assertEquals("$preset / AUTO", old.imageAuto, photoFrameWatermarkFingerprint(image, preset))
            assertEquals("$preset / CENTER", old.imageCenter, photoFrameWatermarkFingerprint(
                image.copy(position = PhotoFrameWatermarkPosition.CENTER), preset))
            // The editor normalizes non-photo IMAGE positions to this actual render position.
            assertEquals("$preset / PHOTO_BOTTOM_CENTER", old.imagePhoto, photoFrameWatermarkFingerprint(
                image.copy(position = PhotoFrameWatermarkPosition.PHOTO_BOTTOM_CENTER), preset))
        }
    }

    private fun identityOfLegacyName(name: String): String = MessageDigest.getInstance("SHA-256")
        .digest(name.lowercase(Locale.ROOT).toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(Locale.ROOT, it.toInt() and 0xff) }

    private data class LegacyFingerprints(
        val auto: String,
        val center: String = auto,
        val disabled: String,
        val imageAuto: String,
        val imageCenter: String = imageAuto,
        val imagePhoto: String,
        val watermarkOnly: String,
    )

    companion object {
        // Captured by running the compiled renderer before watermark-position-v=2 was added.
        // These use default ZTransfer text/default metadata; IMAGE uses SHA-256 "a" repeated 64 times.
        // Keep the literal fixtures: recomputing them from the new serializer would hide regressions.
        private val oldAmbiguousNames = mapOf(
            PhotoFramePreset.CLASSIC_SIGNATURE to "DSC_frame_classic_signature_w11c12abf43d3.jpg",
            PhotoFramePreset.COLOR_ARCHIVE to "DSC_frame_color_archive_w2397b746076e.jpg",
            PhotoFramePreset.FILM_EDGE to "DSC_frame_film_edge_w11c12abf43d3.jpg",
            PhotoFramePreset.PARAMETER_POSTER to "DSC_frame_parameter_poster_w11c12abf43d3.jpg",
        )
        private val standard = LegacyFingerprints(
            auto = "f1e19ec880e4", disabled = "c08a79143377", imageAuto = "1db3df9074ad",
            imagePhoto = "5f66e0fb6394", watermarkOnly = "6c7ad49264a3",
        )
        private val brand = LegacyFingerprints(
            auto = "d770f856e76f", center = "09e8538f9a93", disabled = "fa75d9f4934d",
            imageAuto = "f477bc3a0742", imageCenter = "11163744e6ba",
            imagePhoto = "e75322d38f76", watermarkOnly = "f57021972440",
        )
        private val editorial = LegacyFingerprints(
            auto = "11c12abf43d3", disabled = "6166c0f684de", imageAuto = "71a0bcb85546",
            imagePhoto = "0dbe64d122ed", watermarkOnly = "8d3b9abde215",
        )
        private val oldFingerprints = mapOf(
            PhotoFramePreset.MIST to standard,
            PhotoFramePreset.CINEMA to standard,
            PhotoFramePreset.MINIMAL to standard,
            PhotoFramePreset.FROSTED to LegacyFingerprints(
                auto = "597a63d71c86", disabled = "4625101222a8", imageAuto = "b1d34300c987",
                imagePhoto = "d20e89c03321", watermarkOnly = "0968e0a59c02",
            ),
            PhotoFramePreset.PLAQUE to standard.copy(auto = "d889ebeb5e45", imageAuto = "10f106faab8c"),
            PhotoFramePreset.IMMERSIVE to LegacyFingerprints(
                auto = "e8f098346288", center = "5188c3de1416", disabled = "b4dc66dde806",
                imageAuto = "b044d39b553f", imageCenter = "9dda9524f922",
                imagePhoto = "68147ce547f3", watermarkOnly = "adf9378ffd51",
            ),
            PhotoFramePreset.BRAND_INSET to brand,
            PhotoFramePreset.BRAND_GALLERY to brand,
            PhotoFramePreset.CLASSIC_SIGNATURE to editorial,
            PhotoFramePreset.GALLERY_MAT to editorial,
            PhotoFramePreset.COLOR_ARCHIVE to LegacyFingerprints(
                auto = "2397b746076e", disabled = "1582c5b3ee17", imageAuto = "0e3bbdaca40f",
                imagePhoto = "3315f4aa965b", watermarkOnly = "d6d2fd8d04a9",
            ),
            PhotoFramePreset.FILM_GALLERY to LegacyFingerprints(
                auto = "579734162721", disabled = "2af4f30a6099", imageAuto = "5e3f29af0f29",
                imagePhoto = "6c9ea7a5dac1", watermarkOnly = "fab612910dc0",
            ),
            PhotoFramePreset.FILM_EDGE to editorial,
            PhotoFramePreset.FILM_NEGATIVE to LegacyFingerprints(
                auto = "49c0033c21ac", disabled = "c2ecd2a5993f", imageAuto = "c25b9b3562f5",
                imagePhoto = "ef8d6d6de6a9", watermarkOnly = "0533d59d1dd6",
            ),
            PhotoFramePreset.PARAMETER_POSTER to editorial,
        )
    }
}
