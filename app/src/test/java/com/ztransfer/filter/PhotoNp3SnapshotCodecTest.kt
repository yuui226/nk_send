package com.ztransfer.filter

import java.nio.ByteBuffer
import java.security.MessageDigest
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class PhotoNp3SnapshotCodecTest {
    @Test fun originalFlexibleSnapshotEncodingIsByteForByteStable() {
        val hash = MessageDigest.getInstance("SHA-256").digest(PhotoNp3SnapshotCodec.encode(recipe(true)))
            .joinToString("") { (it.toInt() and 0xff).toString(16).padStart(2, '0') }
        assertEquals("747d79fe0dd567a3d45899113677f12d9cc263a20425a2d99a841404060b61ec", hash)
    }
    @Test fun everyClassicStyleRestoresItsOwnRecipeAndDedupIdentity() {
        for (base in ClassicNp3Style.entries) for (hasCurve in listOf(false, true)) {
            val original = classicRecipe(base, hasCurve)
            val restored = PhotoNp3SnapshotCodec.decode(PhotoNp3SnapshotCodec.encode(original))
            val expected = original.parameters as ClassicNp3PhotoFilterParameters
            val actual = restored.parameters as ClassicNp3PhotoFilterParameters
            assertEquals(original.id, restored.id)
            assertEquals(expected.copy(toneCurve = null), actual.copy(toneCurve = null))
            assertArrayEquals(expected.toneCurve, actual.toneCurve)
            assertEquals(com.ztransfer.frame.photoFilterRenderFingerprint(PhotoFilterSelection(original, 80)),
                com.ztransfer.frame.photoFilterRenderFingerprint(PhotoFilterSelection(restored, 80)))
            expected.toneCurve?.set(0, 100)
            if (hasCurve) assertEquals(0, actual.toneCurve!![0])
        }
    }

    @Test fun recipeTypesCannotBeMixedUnderTheSameRenderingId() {
        val flexible = recipe(false)
        val classic = classicRecipe(ClassicNp3Style.entries.first(), false)
        for (mismatched in listOf(flexible.copy(parameters = classic.parameters),
            classic.copy(parameters = flexible.parameters))) {
            try { PhotoNp3SnapshotCodec.encode(mismatched); fail("Accepted mismatched recipe kind") }
            catch (_: IllegalArgumentException) { }
        }
        val bytes = PhotoNp3SnapshotCodec.encode(classic)
        val payload = bytes.copyOfRange(0, bytes.size - 32)
        rejected(checksum(payload.copyOf().apply { this[8] = 2 }))
        val baseOffset = 9 + 2 + classic.id.toByteArray().size + 2 + classic.name.toByteArray().size
        rejected(checksum(payload.copyOf().apply { ByteBuffer.wrap(this).putInt(baseOffset, 0xeeee) }))
        rejected(checksum(payload.copyOf().apply { ByteBuffer.wrap(this).putInt(baseOffset + 4, 127) }))
    }

    @Test fun restoringCustomRecipesPreservesOutputDedupAndChangedStrengthDoesNotCollide() {
        val original = recipe(true)
        val restored = PhotoNp3SnapshotCodec.decode(PhotoNp3SnapshotCodec.encode(original))
        val first = PhotoFilterSelection(original, 80)
        val same = PhotoFilterSelection(restored, 80)
        assertEquals(com.ztransfer.frame.photoFilterRenderFingerprint(first),
            com.ztransfer.frame.photoFilterRenderFingerprint(same))
        org.junit.Assert.assertNotEquals(com.ztransfer.frame.photoFilterRenderFingerprint(first),
            com.ztransfer.frame.photoFilterRenderFingerprint(same.copy(intensityPercent = 60)))
        org.junit.Assert.assertNotEquals(com.ztransfer.frame.photoFilterRenderFingerprint(first),
            com.ztransfer.frame.photoFilterRenderFingerprint(same.copy(
                preset = restored.copy(id = "np3:${"b".repeat(64)}:np3-srgb-v1"))))
    }

    @Test fun currentRecipeRoundTripsEveryControlAndAllCurveSamples() {
        for (hasCurve in listOf(false, true)) {
            val original = recipe(hasCurve)
            val bytes = PhotoNp3SnapshotCodec.encode(original)
            assertTrue(bytes.size < 2048)
            val restored = PhotoNp3SnapshotCodec.decode(bytes)
            assertEquals(original.id, restored.id)
            assertEquals(original.name, restored.name)
            val expected = original.parameters as Np3PhotoFilterParameters
            val actual = restored.parameters as Np3PhotoFilterParameters
            assertEquals(expected.copy(toneCurve = null), actual.copy(toneCurve = null))
            if (hasCurve) assertArrayEquals(expected.toneCurve, actual.toneCurve)
            else assertNull(actual.toneCurve)
            // The saved recipe owns the curve independently of the editor's arrays.
            expected.toneCurve?.set(0, 1)
            if (hasCurve) assertEquals(0, actual.toneCurve!![0])
        }
    }

    @Test fun truncatedCorruptedTrailingAndOversizedSnapshotsAreRejected() {
        val bytes = PhotoNp3SnapshotCodec.encode(recipe(true))
        val failures = listOf(
            bytes.copyOf(bytes.size - 1),
            bytes + byteArrayOf(0),
            bytes.copyOf().apply { this[size / 2] = (this[size / 2].toInt() xor 1).toByte() },
            ByteArray(PhotoNp3SnapshotCodec.MAX_BYTES + 1),
            checksum(bytes.copyOfRange(0, bytes.size - 32) + byteArrayOf(0)),
        )
        failures.forEach(::rejected)
    }

    @Test fun validChecksumCannotMakeInvalidVersionControlsOrCurveSamplesAcceptable() {
        val bytes = PhotoNp3SnapshotCodec.encode(recipe(true))
        val payload = bytes.copyOfRange(0, bytes.size - 32)
        rejected(checksum(payload.copyOf().apply { ByteBuffer.wrap(this).putInt(4, 2) }))
        // writeUTF's two-byte length precedes each string, then the six signed controls.
        val controlsOffset = 8 + 2 + recipe(true).id.toByteArray().size + 2 + recipe(true).name.toByteArray().size
        rejected(checksum(payload.copyOf().apply { ByteBuffer.wrap(this).putInt(controlsOffset, 101) }))
        rejected(checksum(payload.copyOf().apply { this[size - 1] = -1; this[size - 2] = -1 }))
    }

    private fun rejected(bytes: ByteArray) {
        try { PhotoNp3SnapshotCodec.decode(bytes); fail("Accepted a broken recipe") }
        catch (_: IllegalArgumentException) { }
        catch (_: java.io.IOException) { }
    }

    private fun checksum(payload: ByteArray) = payload + MessageDigest.getInstance("SHA-256").digest(payload)

    private fun classicRecipe(base: ClassicNp3Style, curve: Boolean) = PhotoFilterPreset(
        "np3:${"c".repeat(64)}:np3-classic-srgb-v1", "Classic fixture",
        ClassicNp3PhotoFilterParameters(base, -128, -6, -128, 12,
            0, 0, 16, if (base.creative) 40 else 100,
            if (curve) IntArray(257) { it * 32767 / 256 } else null),
    )

    private fun recipe(hasCurve: Boolean) = PhotoFilterPreset(
        "np3:${"a".repeat(64)}:np3-srgb-v1", "NP3 fixture", Np3PhotoFilterParameters(
            -100, -57, -3, 2, 51, 100,
            PHOTO_FILTER_COLOR_BAND_CENTERS.mapIndexed { index, center ->
                PhotoFilterColorBand(center, index - 7, index * 12, 100 - index * 11)
            },
            if (hasCurve) IntArray(257) { index -> index * 32767 / 256 } else null,
        ),
    )
}
