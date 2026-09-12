package com.ztransfer.protocol

import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Test

/** Locks the pre-shared Android format-locale behavior used by camera fallback metadata. */
class CameraMetadataLocaleParityTest {
    @Test
    fun fallbackNamesAndBulkDatesUseAndroidFormatLocale() {
        val locale = Locale.forLanguageTag("ar-EG")
        val formatter: (Int, Int) -> String = { value, width ->
            formatAndroidCameraMetadataDecimal(value, width, locale)
        }

        val expectedNumber = String.format(locale, "%04d", 42)
        assertEquals(
            "DSC_$expectedNumber.JPG",
            nikonDefaultCameraFileName(NikonMakerFileInfo(101, 42), ".jpg", formatter),
        )
        assertEquals(
            "DSC_$expectedNumber.jpg",
            parseObjectCacheIdentity(42, ".jpg", ByteArray(53), formatter).fileName,
        )

        val metadata = ByteArray(24).also { bytes ->
            bytes.writeInt32LittleEndian(0, 100)
            bytes.writeInt32LittleEndian(4, 1)
            bytes.writeInt32LittleEndian(8, 7)
            bytes[17] = 3
            bytes[18] = 2
            bytes[19] = 1
            bytes[20] = 5
            bytes[21] = 9
            bytes[22] = 0xEA.toByte()
            bytes[23] = 0x07
        }
        assertEquals(
            String.format(locale, "%04d%02d%02dT%02d%02d%02d", 2026, 9, 5, 1, 2, 3),
            parseNikonObjectsMetadataCaptureDates(metadata, formatter)[7],
        )
    }

    private fun ByteArray.writeInt32LittleEndian(offset: Int, value: Int) {
        repeat(4) { index -> this[offset + index] = (value ushr (index * 8)).toByte() }
    }
}
