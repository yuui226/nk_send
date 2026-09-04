package com.ztransfer.protocol

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class NikonObjectMetadataTest {
    @Test
    fun derivesFileNumbersAcrossMediaKindsAndDirectoryBoundaries() {
        val anchor = NikonFileNumberAnchor(
            handleSequence = 0x1961F5,
            directoryNumber = 101,
            fileNumber = 8693,
        )
        assertEquals(
            NikonMakerFileInfo(101, 8692),
            deriveNikonMakerFileInfo(anchor, 0x611961F4),
        )
        assertEquals(
            NikonMakerFileInfo(101, 8679),
            deriveNikonMakerFileInfo(anchor, 0x091961E7),
        )

        assertEquals(
            NikonMakerFileInfo(100, 9999),
            deriveNikonMakerFileInfo(NikonFileNumberAnchor(10, 101, 0), 9),
        )
        assertEquals(
            NikonMakerFileInfo(100, 0),
            deriveNikonMakerFileInfo(NikonFileNumberAnchor(10_000, 101, 0), 0),
        )
        assertEquals(
            NikonMakerFileInfo(102, 0),
            deriveNikonMakerFileInfo(NikonFileNumberAnchor(10, 101, 9999), 11),
        )
        assertEquals(
            NikonMakerFileInfo(99, 9999),
            deriveNikonMakerFileInfo(NikonFileNumberAnchor(1, 100, 0), 0),
        )
        assertNull(deriveNikonMakerFileInfo(NikonFileNumberAnchor(1, 99, 0), 0))
        assertNull(deriveNikonMakerFileInfo(NikonFileNumberAnchor(1, 999, 9999), 2))
    }

    @Test
    fun defaultNamesNormalizeKnownExtensionsOnly() {
        assertEquals(
            "DSC_8692.MP4",
            nikonDefaultCameraFileName(NikonMakerFileInfo(101, 8692), ".mp4"),
        )
        assertEquals(
            "DSC_0042.JPEG",
            nikonDefaultCameraFileName(NikonMakerFileInfo(101, 42), "jpeg"),
        )
        assertNull(nikonDefaultCameraFileName(NikonMakerFileInfo(101, 42), ".bin"))
    }

    @Test
    fun parsesTheKnownBulkMetadataVector() {
        assertEquals(
            mapOf(0x291961F5 to "20260824T204540"),
            parseNikonObjectsMetadataCaptureDates(
                hex("6400000001000000F56119290000000000282D141808EA07"),
            ),
        )
        assertEquals(
            mapOf(
                0x291961F5 to "20260824T204540",
                0x611961F4 to "20260823T145645",
            ),
            parseNikonObjectsMetadataCaptureDates(
                payload(
                    record(0x291961F5, 2026, 8, 24, 20, 45, 40),
                    record(0x611961F4, 2026, 8, 23, 14, 56, 45),
                ),
            ),
        )
    }

    @Test
    fun bulkMetadataRequiresExactKnownLayout() {
        val valid = payload(record(1, 2026, 8, 24, 20, 45, 40))
        assertEquals(emptyMap(), parseNikonObjectsMetadataCaptureDates(null))
        assertEquals(emptyMap(), parseNikonObjectsMetadataCaptureDates(ByteArray(7)))
        assertEquals(emptyMap(), parseNikonObjectsMetadataCaptureDates(valid.copyOf(7)))
        assertEquals(
            emptyMap(),
            parseNikonObjectsMetadataCaptureDates(valid.copyOf(valid.size - 1)),
        )
        assertEquals(emptyMap(), parseNikonObjectsMetadataCaptureDates(valid + 0))

        val wrongVersion = valid.copyOf().also { it.writeInt32(0, 99) }
        assertEquals(emptyMap(), parseNikonObjectsMetadataCaptureDates(wrongVersion))
        val zeroCount = valid.copyOf(8).also { it.writeInt32(4, 0) }
        assertEquals(emptyMap(), parseNikonObjectsMetadataCaptureDates(zeroCount))
        val impossibleCount = valid.copyOf().also { it.writeInt32(4, Int.MAX_VALUE) }
        assertEquals(emptyMap(), parseNikonObjectsMetadataCaptureDates(impossibleCount))
    }

    @Test
    fun invalidRecordsAreSkippedAndDuplicateHandlesUseTheLatestDate() {
        val data = payload(
            record(0, 2026, 8, 24, 20, 45, 40),
            record(7, 1989, 8, 24, 20, 45, 40),
            record(8, 2026, 13, 24, 20, 45, 40),
            record(9, 2026, 8, 24, 24, 45, 40),
            record(10, 2026, 2, 31, 20, 45, 60),
            record(10, 2027, 2, 31, 20, 45, 60),
            record(0x891961F5.toInt(), 2026, 1, 1, 0, 0, 0),
        )

        assertEquals(
            mapOf(
                10 to "20270231T204560",
                0x891961F5.toInt() to "20260101T000000",
            ),
            parseNikonObjectsMetadataCaptureDates(data),
        )
    }

    @Test
    fun mapsOnlyObservedPairedStaHandleKinds() {
        assertEquals(".jpg", staDirectExtensionFromHandle(0x291961F5))
        assertEquals(".nef", staDirectExtensionFromHandle(0x091961E7))
        assertEquals(".mp4", staDirectExtensionFromHandle(0x611961F4))
        assertNull(staDirectExtensionFromHandle(0x7F1961F4))
    }

    private fun payload(vararg records: ByteArray): ByteArray =
        ByteArray(8 + records.size * 16).also { bytes ->
            bytes.writeInt32(0, 100)
            bytes.writeInt32(4, records.size)
            records.forEachIndexed { index, record -> record.copyInto(bytes, 8 + index * 16) }
        }

    private fun record(
        handle: Int,
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        second: Int,
    ): ByteArray = ByteArray(16).also { bytes ->
        bytes.writeInt32(0, handle)
        bytes[9] = second.toByte()
        bytes[10] = minute.toByte()
        bytes[11] = hour.toByte()
        bytes[12] = day.toByte()
        bytes[13] = month.toByte()
        bytes[14] = year.toByte()
        bytes[15] = (year ushr 8).toByte()
    }

    private fun ByteArray.writeInt32(offset: Int, value: Int) {
        repeat(4) { index -> this[offset + index] = (value ushr (index * 8)).toByte() }
    }

    private fun hex(value: String): ByteArray = value.chunked(2)
        .map { it.toInt(16).toByte() }
        .toByteArray()
}
