package com.ztransfer.frame

import com.ztransfer.filter.CubePhotoFilterParameters
import com.ztransfer.filter.LutAdjustments
import com.ztransfer.filter.NcpPhotoFilterParameters
import com.ztransfer.filter.PhotoFilterPreset
import com.ztransfer.filter.PhotoFilterSelection
import com.ztransfer.lut.CubeLutParser
import com.ztransfer.grain.PhotoGrainSettings
import com.ztransfer.grain.PhotoGrainStyle
import com.ztransfer.grain.photoGrainSeed
import java.security.MessageDigest
import java.util.Locale
import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PhotoEffectOutputNamingTest {
    private val watermark = PhotoFrameWatermark(text = "Studio")
    private val noWatermark = PhotoFrameWatermark(enabled = false)
    private val filter = PhotoFilterSelection(
        PhotoFilterPreset(
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

    @Test
    fun namesDescribeTheVisibleEffectWithoutExposingConfiguration() {
        assertEquals(
            "DSC_0001_f.jpg",
            photoFrameOutputName("DSC_0001.JPG", PhotoFramePreset.MIST),
        )
        assertEquals(
            "DSC_0001_f.jpg",
            photoFrameOutputName("DSC_0001.JPG", PhotoFramePreset.MIST, noWatermark),
        )
        assertEquals(
            "DSC_0001_w.jpg",
            photoFrameOutputName(
                "DSC_0001.JPG", PhotoFramePreset.MIST, watermark, borderEnabled = false,
            ),
        )
        assertEquals(
            "DSC_0001_e.jpg",
            photoFrameOutputName(
                "DSC_0001.JPG", PhotoFramePreset.MIST, noWatermark,
                borderEnabled = false, filter = filter,
            ),
        )
        assertEquals(
            "DSC_0001_f_e.jpg",
            photoFrameOutputName(
                "DSC_0001.JPG", PhotoFramePreset.MIST, watermark, filter = filter,
            ),
        )
        assertEquals(
            "DSC_0001_w_e.jpg",
            photoFrameOutputName(
                "DSC_0001.JPG", PhotoFramePreset.MIST, watermark,
                borderEnabled = false, filter = filter,
            ),
        )
    }

    @Test
    fun grainAddsOneShortMarkerAfterExistingEffects() {
        val grain = PhotoGrainSettings(40, enabled = true)
        assertEquals("DSC_g.jpg", photoFrameOutputName(
            "DSC.JPG", PhotoFramePreset.MIST, noWatermark,
            borderEnabled = false, grain = grain,
        ))
        assertEquals("DSC_f_g.jpg", photoFrameOutputName(
            "DSC.JPG", PhotoFramePreset.MIST, grain = grain,
        ))
        assertEquals("DSC_w_g.jpg", photoFrameOutputName(
            "DSC.JPG", PhotoFramePreset.MIST, watermark,
            borderEnabled = false, grain = grain,
        ))
        assertEquals("DSC_c_f_e_g.jpg", photoFrameOutputName(
            "DSC_c.JPG", PhotoFramePreset.MIST, filter = filter, grain = grain,
        ))
        assertEquals("DSC_w_e_g.jpg", photoFrameOutputName(
            "DSC.JPG", PhotoFramePreset.MIST, watermark,
            borderEnabled = false, filter = filter, grain = grain,
        ))
        assertEquals("DSC_e_g.jpg", photoFrameOutputName(
            "DSC.JPG", PhotoFramePreset.MIST, noWatermark,
            borderEnabled = false, filter = filter, grain = grain,
        ))
    }

    @Test
    fun disabledGrainPreservesLegacyNamesAndIdentityExactly() {
        val legacy = legacyPhotoFrameOutputName(
            "DSC.JPG", PhotoFramePreset.MIST, watermark, filter = filter,
        )
        val legacyIdentity = MessageDigest.getInstance("SHA-256")
            .digest(legacy.lowercase(Locale.ROOT).toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(Locale.ROOT, it.toInt() and 0xff) }
        PhotoGrainStyle.entries.flatMap { style ->
            listOf(
                PhotoGrainSettings.OFF.copy(style = style),
                PhotoGrainSettings(-10, enabled = true, style = style),
                PhotoGrainSettings(73, enabled = false, style = style),
            )
        }.forEach { grain ->
            assertEquals("DSC_f_e.jpg", photoFrameOutputName(
                "DSC.JPG", PhotoFramePreset.MIST, watermark, filter = filter, grain = grain,
            ))
            assertEquals(legacyIdentity, photoFrameOutputIdentity(
                "DSC.JPG", PhotoFramePreset.MIST, watermark, filter = filter, grain = grain,
            ))
            assertTrue(isPhotoFrameOutputFor(
                legacy, "DSC.JPG", PhotoFramePreset.MIST, watermark, filter = filter, grain = grain,
            ))
        }
    }

    @Test
    fun fineGrainPreservesItsExistingVersionOneIdentity() {
        val legacy = legacyPhotoFrameOutputName(
            "DSC.JPG", PhotoFramePreset.MIST, watermark, filter = filter,
        )
        val versionOneInput = legacy.lowercase(Locale.ROOT) +
            "\u0000grain-v=1\u0000i=40\u0000seed=${photoGrainSeed("DSC.JPG")}"
        val versionOneIdentity = MessageDigest.getInstance("SHA-256")
            .digest(versionOneInput.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(Locale.ROOT, it.toInt() and 0xff) }
        val fine = PhotoGrainSettings(40, enabled = true, style = PhotoGrainStyle.FINE)

        assertEquals(versionOneIdentity, photoFrameOutputIdentity(
            "DSC.JPG", PhotoFramePreset.MIST, watermark, filter = filter, grain = fine,
        ))
        assertTrue(isPhotoFrameOutputFor(
            "DSC_f_e_g (2).jpg", "DSC.JPG", PhotoFramePreset.MIST, watermark,
            filter = filter, identity = versionOneIdentity, grain = fine,
        ))
    }

    @Test
    fun sameAmountOfDifferentGrainStylesKeepsShortNamesButNeverDeduplicates() {
        val identities = PhotoGrainStyle.entries.associateWith { style ->
            photoFrameOutputIdentity(
                "DSC.JPG", PhotoFramePreset.MIST,
                grain = PhotoGrainSettings(40, enabled = true, style = style),
            )
        }
        assertEquals(PhotoGrainStyle.entries.size, identities.values.toSet().size)
        PhotoGrainStyle.entries.forEach { requestedStyle ->
            val settings = PhotoGrainSettings(40, enabled = true, style = requestedStyle)
            assertEquals("DSC_f_g.jpg", photoFrameOutputName(
                "DSC.JPG", PhotoFramePreset.MIST, grain = settings,
            ))
            identities.forEach { (savedStyle, savedIdentity) ->
                assertEquals(
                    "saved=$savedStyle requested=$requestedStyle",
                    savedStyle == requestedStyle,
                    isPhotoFrameOutputFor(
                        "DSC_f_g (1).jpg", "DSC.JPG", PhotoFramePreset.MIST,
                        identity = savedIdentity, grain = settings,
                    ),
                )
            }
        }
    }

    @Test
    fun grainDedupRequiresTheSameNormalizedAmountAndSeed() {
        val grain = PhotoGrainSettings(40, enabled = true)
        val identity = photoFrameOutputIdentity("DSC.JPG", PhotoFramePreset.MIST, grain = grain)
        assertEquals(identity, photoFrameOutputIdentity("dsc.jpg", PhotoFramePreset.MIST, grain = grain))
        assertNotEquals(identity, photoFrameOutputIdentity("DSC.JPG", PhotoFramePreset.MIST))
        assertNotEquals(identity, photoFrameOutputIdentity(
            "DSC.JPG", PhotoFramePreset.MIST, grain = PhotoGrainSettings(41, enabled = true),
        ))
        // Extensions are part of the grain seed even though the old visible stem omits them.
        assertNotEquals(identity, photoFrameOutputIdentity("DSC.JPEG", PhotoFramePreset.MIST, grain = grain))
        assertEquals(
            photoFrameOutputIdentity("DSC.JPG", PhotoFramePreset.MIST, grain = PhotoGrainSettings(100, enabled = true)),
            photoFrameOutputIdentity("DSC.JPG", PhotoFramePreset.MIST, grain = PhotoGrainSettings(500, enabled = true)),
        )
        assertTrue(isPhotoFrameOutputFor(
            "DSC_f_g (2).jpg", "DSC.JPG", PhotoFramePreset.MIST, identity = identity, grain = grain,
        ))
        assertFalse(isPhotoFrameOutputFor(
            "DSC_f_g.jpg", "DSC.JPG", PhotoFramePreset.MIST, grain = grain,
        ))
        assertFalse(isPhotoFrameOutputFor(
            "DSC_f_g.jpg", "DSC.JPG", PhotoFramePreset.MIST,
            identity = identity, grain = PhotoGrainSettings(41, enabled = true),
        ))
    }

    @Test
    fun grainNeverReusesAnOlderOutputWithoutGrain() {
        val grain = PhotoGrainSettings(40, enabled = true)
        val legacy = legacyPhotoFrameOutputName("DSC.JPG", PhotoFramePreset.MIST)
        val oldIdentity = photoFrameOutputIdentity("DSC.JPG", PhotoFramePreset.MIST)
        val grainIdentity = photoFrameOutputIdentity("DSC.JPG", PhotoFramePreset.MIST, grain = grain)
        assertFalse(isPhotoFrameOutputFor(legacy, "DSC.JPG", PhotoFramePreset.MIST, grain = grain))
        assertFalse(isPhotoFrameOutputFor(
            "DSC_f.jpg", "DSC.JPG", PhotoFramePreset.MIST, identity = oldIdentity, grain = grain,
        ))
        assertFalse(isPhotoFrameOutputFor(
            "DSC_f_g.jpg", "DSC.JPG", PhotoFramePreset.MIST, identity = oldIdentity, grain = grain,
        ))
        assertFalse(hasPhotoEffectOutput(setOf(legacy), "DSC_f_g.jpg", null, grainIdentity) {
            error("Legacy ungrained names must not be read as grain candidates")
        })
    }

    @Test
    fun grainMarkersNeedMetadataAndPreserveCollisionNumbering() {
        val identity = photoFrameOutputIdentity("DSC.JPG", PhotoFramePreset.MIST, grain = PhotoGrainSettings(30, enabled = true))
        listOf("DSC_g.jpg", "DSC_f_g.jpg", "DSC_w_e_g (2).jpg", "DSC_c_e_g.JPG").forEach { name ->
            assertTrue(isShortPhotoFrameOutputName(name))
            assertFalse(isPhotoFrameOutputName(name))
            assertTrue(isPhotoFrameOutputName(name, identity))
        }
        assertEquals("DSC_g (2).jpg", uniqueName("DSC_g.jpg", setOf("DSC_g.jpg", "DSC_g (1).jpg")))
    }

    @Test
    fun croppedSourceKeepsItsCropMarkerBeforeEffectMarkers() {
        assertEquals(
            "DSC_c_f.jpg",
            photoFrameOutputName("DSC_c.JPG", PhotoFramePreset.MIST),
        )
        assertEquals(
            "DSC_c (1)_f_e.jpg",
            photoFrameOutputName("DSC_c (1).jpg", PhotoFramePreset.MIST, filter = filter),
        )
    }

    @Test
    fun identityIsStableAndTreatsSourceNamesCaseInsensitively() {
        val identity = photoFrameOutputIdentity("DSC_0001.JPG", PhotoFramePreset.MIST)

        assertTrue(identity.matches(Regex("[0-9a-f]{64}")))
        assertEquals(identity, photoFrameOutputIdentity("DSC_0001.JPG", PhotoFramePreset.MIST))
        assertEquals(identity, photoFrameOutputIdentity("dsc_0001.jpg", PhotoFramePreset.MIST))
        assertNotEquals(identity, photoFrameOutputIdentity("DSC_0002.JPG", PhotoFramePreset.MIST))
    }

    @Test
    fun changingBorderStyleChangesIdentityButKeepsShortName() {
        assertEquals(
            photoFrameOutputName("DSC.JPG", PhotoFramePreset.MIST),
            photoFrameOutputName("DSC.JPG", PhotoFramePreset.CINEMA),
        )
        assertNotEquals(
            photoFrameOutputIdentity("DSC.JPG", PhotoFramePreset.MIST),
            photoFrameOutputIdentity("DSC.JPG", PhotoFramePreset.CINEMA),
        )
    }

    @Test
    fun changingWatermarkChangesIdentityButKeepsShortName() {
        val other = watermark.copy(text = "Another Studio")
        assertEquals(
            photoFrameOutputName("DSC.JPG", PhotoFramePreset.MIST, watermark),
            photoFrameOutputName("DSC.JPG", PhotoFramePreset.MIST, other),
        )
        assertNotEquals(
            photoFrameOutputIdentity("DSC.JPG", PhotoFramePreset.MIST, watermark),
            photoFrameOutputIdentity("DSC.JPG", PhotoFramePreset.MIST, other),
        )
    }

    @Test
    fun changingBorderWidthChangesIdentityButKeepsShortName() {
        val original = defaultPhotoFrameMetadataSettings(PhotoFramePreset.MIST)
        val narrower = original.copy(widthPercent = 80)
        assertEquals(
            photoFrameOutputName("DSC.JPG", PhotoFramePreset.MIST, metadataSettings = original),
            photoFrameOutputName("DSC.JPG", PhotoFramePreset.MIST, metadataSettings = narrower),
        )
        assertNotEquals(
            photoFrameOutputIdentity("DSC.JPG", PhotoFramePreset.MIST, metadataSettings = original),
            photoFrameOutputIdentity("DSC.JPG", PhotoFramePreset.MIST, metadataSettings = narrower),
        )
    }

    @Test
    fun changingFilterOrIntensityChangesIdentityButKeepsShortName() {
        val changedFilters = listOf(
            filter.copy(intensityPercent = 74),
            filter.copy(preset = filter.preset.copy(id = "fedcba9876543210")),
        )
        val name = photoFrameOutputName("DSC.JPG", PhotoFramePreset.MIST, filter = filter)
        val identity = photoFrameOutputIdentity("DSC.JPG", PhotoFramePreset.MIST, filter = filter)

        changedFilters.forEach { changed ->
            assertEquals(name, photoFrameOutputName("DSC.JPG", PhotoFramePreset.MIST, filter = changed))
            assertNotEquals(
                identity,
                photoFrameOutputIdentity("DSC.JPG", PhotoFramePreset.MIST, filter = changed),
            )
        }
    }

    @Test
    fun changingEachLutAdjustmentChangesIdentityButKeepsShortName() {
        val table = CubeLutParser.parse(
            (
                "LUT_3D_SIZE 2\n" +
                    "0 0 0\n1 0 0\n0 1 0\n1 1 0\n" +
                    "0 0 1\n1 0 1\n0 1 1\n1 1 1\n"
                ).byteInputStream(),
        )
        val lut = PhotoFilterSelection(
            PhotoFilterPreset("cube:test", "LUT", CubePhotoFilterParameters(table)),
            intensityPercent = 80,
        )
        val name = photoFrameOutputName("DSC.JPG", PhotoFramePreset.MIST, filter = lut)
        val identity = photoFrameOutputIdentity("DSC.JPG", PhotoFramePreset.MIST, filter = lut)
        val adjustments = listOf(
            LutAdjustments(contrast = 10),
            LutAdjustments(saturation = 10),
            LutAdjustments(highlights = 10),
            LutAdjustments(shadows = 10),
        )

        adjustments.forEach { adjustment ->
            val changed = lut.copy(lutAdjustments = adjustment)
            assertEquals(name, photoFrameOutputName("DSC.JPG", PhotoFramePreset.MIST, filter = changed))
            assertNotEquals(
                identity,
                photoFrameOutputIdentity("DSC.JPG", PhotoFramePreset.MIST, filter = changed),
            )
        }
    }

    @Test
    fun shortNamesRequireMatchingIdentityToSkipAnExistingOutput() {
        val name = photoFrameOutputName("DSC.JPG", PhotoFramePreset.MIST)
        val identity = photoFrameOutputIdentity("DSC.JPG", PhotoFramePreset.MIST)
        val otherIdentity = photoFrameOutputIdentity("DSC.JPG", PhotoFramePreset.CINEMA)

        assertTrue(isPhotoFrameOutputFor(name, "DSC.JPG", PhotoFramePreset.MIST, identity = identity))
        assertFalse(isPhotoFrameOutputFor(name, "DSC.JPG", PhotoFramePreset.MIST))
        assertFalse(isPhotoFrameOutputFor(name, "DSC.JPG", PhotoFramePreset.MIST, identity = ""))
        assertFalse(isPhotoFrameOutputFor(name, "DSC.JPG", PhotoFramePreset.MIST, identity = otherIdentity))
        assertFalse(isPhotoFrameOutputFor(name, "DSC.JPG", PhotoFramePreset.CINEMA, identity = identity))
        assertFalse(isPhotoFrameOutputFor(name, "DSC_OTHER.JPG", PhotoFramePreset.MIST, identity = identity))
    }

    @Test
    fun numberedShortNamesUseTheSameIdentity() {
        val identity = photoFrameOutputIdentity("DSC.JPG", PhotoFramePreset.MIST)

        listOf("DSC_f.jpg", "DSC_f (1).jpg", "dsc_f (1000).JPG").forEach { name ->
            assertTrue(isPhotoFrameOutputFor(name, "DSC.JPG", PhotoFramePreset.MIST, identity = identity))
            assertFalse(isPhotoFrameOutputFor(name, "DSC.JPG", PhotoFramePreset.MIST))
        }
        assertFalse(
            isPhotoFrameOutputFor("DSC_w.jpg", "DSC.JPG", PhotoFramePreset.MIST, identity = identity),
        )
    }

    @Test
    fun shortNameClassificationRequiresMetadataSoOriginalPhotosAreNotHidden() {
        val identity = photoFrameOutputIdentity("DSC.JPG", PhotoFramePreset.MIST)
        listOf("DSC_f.jpg", "DSC_w_e (2).JPG", "DSC_c_e.jpg").forEach { name ->
            assertTrue(isPhotoFrameOutputName(name, identity = identity))
            assertFalse(isPhotoFrameOutputName(name))
            assertFalse(isPhotoFrameOutputName(name, identity = ""))
            assertFalse(isPhotoFrameOutputName(name, identity = "f".repeat(63)))
            assertFalse(isPhotoFrameOutputName(name, identity = "z".repeat(64)))
        }
        assertFalse(isPhotoFrameOutputName("DSC.JPG", identity = identity))
        assertTrue(isPhotoFrameOutputName("DSC_frame_mist.jpg"))
    }

    @Test
    fun oldNamesStillMatchTheirOriginalConfigurationWithoutMetadata() {
        val legacy = legacyPhotoFrameOutputName("DSC.JPG", PhotoFramePreset.MIST, watermark)
        val numbered = legacy.substringBeforeLast('.') + " (3).jpg"
        val timestamped = legacy.substringBeforeLast('.') + "_123456.jpg"

        listOf(legacy, numbered, timestamped).forEach { name ->
            assertTrue(isPhotoFrameOutputFor(name, "DSC.JPG", PhotoFramePreset.MIST, watermark))
            assertFalse(isPhotoFrameOutputFor(name, "DSC.JPG", PhotoFramePreset.CINEMA, watermark))
            assertFalse(
                isPhotoFrameOutputFor(
                    name, "DSC.JPG", PhotoFramePreset.MIST, watermark.copy(text = "Other Studio"),
                ),
            )
        }
    }

    @Test
    fun legacyLookupDoesNotReadMetadataWhenTheOldNameAlreadyMatches() {
        val shortName = photoFrameOutputName("DSC.JPG", PhotoFramePreset.MIST)
        val legacy = legacyPhotoFrameOutputName("DSC.JPG", PhotoFramePreset.MIST)
        val identity = photoFrameOutputIdentity("DSC.JPG", PhotoFramePreset.MIST)
        val numbered = legacy.substringBeforeLast('.') + " (2).jpg"

        assertTrue(
            hasPhotoEffectOutput(
                occupiedNames = setOf(shortName, numbered),
                shortName = shortName,
                legacyName = legacy,
                identity = identity,
            ) { error("Legacy filename matching must not require metadata") },
        )
    }

    @Test
    fun shortOutputCanBeRediscoveredFromSavedMetadataAfterRestart() {
        val shortName = photoFrameOutputName("DSC.JPG", PhotoFramePreset.MIST)
        val legacy = legacyPhotoFrameOutputName("DSC.JPG", PhotoFramePreset.MIST)
        val identity = photoFrameOutputIdentity("DSC.JPG", PhotoFramePreset.MIST)
        val savedMetadata = mapOf("DSC_f (1000).jpg" to identity)
        val readNames = mutableListOf<String>()

        assertTrue(
            hasPhotoEffectOutput(
                occupiedNames = savedMetadata.keys,
                shortName = shortName,
                legacyName = legacy,
                identity = identity,
            ) { name ->
                readNames.add(name)
                savedMetadata[name]
            },
        )
        assertEquals(listOf("DSC_f (1000).jpg"), readNames)
    }

    @Test
    fun missingOrInvalidMetadataDoesNotSkipAShortNamedOutput() {
        val shortName = photoFrameOutputName("DSC.JPG", PhotoFramePreset.MIST)
        val legacy = legacyPhotoFrameOutputName("DSC.JPG", PhotoFramePreset.MIST)
        val identity = photoFrameOutputIdentity("DSC.JPG", PhotoFramePreset.MIST)

        listOf(null, "", "broken", "f".repeat(63), "0".repeat(64)).forEach { savedIdentity ->
            assertFalse(
                hasPhotoEffectOutput(
                    occupiedNames = setOf(shortName),
                    shortName = shortName,
                    legacyName = legacy,
                    identity = identity,
                ) { savedIdentity },
            )
        }
    }

    @Test
    fun shortOutputWithPreviousParametersDoesNotMaskANewRender() {
        val shortName = photoFrameOutputName("DSC.JPG", PhotoFramePreset.MIST)
        val previousIdentity = photoFrameOutputIdentity("DSC.JPG", PhotoFramePreset.CINEMA)

        assertFalse(
            hasPhotoEffectOutput(
                occupiedNames = setOf(shortName),
                shortName = shortName,
                legacyName = legacyPhotoFrameOutputName("DSC.JPG", PhotoFramePreset.MIST),
                identity = photoFrameOutputIdentity("DSC.JPG", PhotoFramePreset.MIST),
            ) { previousIdentity },
        )
    }

    @Test
    fun lookupReadsOnlyMatchingSourceAndEffectCandidates() {
        val shortName = photoFrameOutputName("DSC.JPG", PhotoFramePreset.MIST)
        val identity = photoFrameOutputIdentity("DSC.JPG", PhotoFramePreset.MIST)
        val numbered = "dsc_f (2).JPG"
        val readNames = mutableListOf<String>()

        assertTrue(
            hasPhotoEffectOutput(
                occupiedNames = linkedSetOf(
                    "OTHER_f.jpg", "DSC.JPG", "DSC_w.jpg", "DSC_f_e.jpg", shortName, numbered,
                ),
                shortName = shortName,
                legacyName = legacyPhotoFrameOutputName("DSC.JPG", PhotoFramePreset.MIST),
                identity = identity,
            ) { name ->
                readNames.add(name)
                if (name == numbered) identity else null
            },
        )
        assertEquals(listOf(shortName, numbered), readNames)
    }

    @Test
    fun caseVariantFilesKeepSeparateIdentitiesDuringLookup() {
        val documents = linkedMapOf(
            "DSC_f.jpg" to photoFrameOutputIdentity("DSC.JPG", PhotoFramePreset.MIST),
            "dsc_f.JPG" to photoFrameOutputIdentity("DSC.JPG", PhotoFramePreset.CINEMA),
        )
        for (preset in listOf(PhotoFramePreset.MIST, PhotoFramePreset.CINEMA)) {
            val readNames = mutableListOf<String>()
            assertTrue(
                hasPhotoEffectOutput(
                    occupiedNames = documents.keys,
                    shortName = photoFrameOutputName("DSC.JPG", preset),
                    legacyName = legacyPhotoFrameOutputName("DSC.JPG", preset),
                    identity = photoFrameOutputIdentity("DSC.JPG", preset),
                ) { name ->
                    readNames.add(name)
                    documents[name]
                },
            )
            assertEquals(
                if (preset == PhotoFramePreset.MIST) listOf("DSC_f.jpg") else documents.keys.toList(),
                readNames,
            )
        }
    }

    @Test
    fun diskRescanFindsOnlyExistingJpegsWithMatchingEffectMetadata() {
        val directory = Files.createTempDirectory("photo-effect-identity-").toFile()
        try {
            val sourceName = "DSC.JPG"
            val jpeg = checkNotNull(javaClass.getResourceAsStream("/photo-effects/sample.jpg")).use {
                it.readBytes()
            }
            fun names(): Set<String> = checkNotNull(directory.list()).toSet()
            fun save(preset: PhotoFramePreset): File {
                val name = uniqueName(photoFrameOutputName(sourceName, preset), names())
                val file = File(directory, name)
                PhotoEffectIdentityJpeg.outputStream(
                    file.outputStream(),
                    photoFrameOutputIdentity(sourceName, preset),
                ).use { output ->
                    output.write(jpeg)
                }
                return file
            }
            fun found(preset: PhotoFramePreset): Boolean =
                hasPhotoEffectOutput(
                    occupiedNames = names(),
                    shortName = photoFrameOutputName(sourceName, preset),
                    legacyName = legacyPhotoFrameOutputName(sourceName, preset),
                    identity = photoFrameOutputIdentity(sourceName, preset),
                ) { name ->
                    File(directory, name).inputStream().use(PhotoEffectIdentityJpeg::read)
                }

            assertFalse(found(PhotoFramePreset.MIST))
            val first = save(PhotoFramePreset.MIST)
            assertEquals("DSC_f.jpg", first.name)
            assertTrue(found(PhotoFramePreset.MIST))
            assertFalse(found(PhotoFramePreset.CINEMA))

            val second = save(PhotoFramePreset.CINEMA)
            assertEquals("DSC_f (1).jpg", second.name)
            assertTrue(found(PhotoFramePreset.MIST))
            assertTrue(found(PhotoFramePreset.CINEMA))

            assertTrue(first.delete())
            assertFalse(found(PhotoFramePreset.MIST))
            assertTrue(found(PhotoFramePreset.CINEMA))
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun duplicateSequenceContinuesPastNineHundredAndNinetyNine() {
        val occupied = buildSet {
            add("DSC_f.jpg")
            for (index in 1..999) add("DSC_f ($index).jpg")
        }

        assertEquals("DSC_f (1000).jpg", uniqueName("DSC_f.jpg", occupied))
    }
}
