package com.ztransfer.viewmodel

import org.junit.Assert.assertEquals
import org.junit.Test

class JpegMetadataHeaderTest {
    private fun bytes(vararg values: Int) = values.map(Int::toByte).toByteArray()

    @Test fun completeExifDoesNotRequireTheImageOrGps() {
        val header = bytes(255, 216, 255, 225, 0, 10, 69, 120, 105, 102, 0, 0, 73, 73)
        assertEquals(JpegMetadataHeader.EXIF_COMPLETE, inspectJpegMetadataHeader(header))
        assertEquals(JpegMetadataHeader.INCOMPLETE, inspectJpegMetadataHeader(header.copyOf(12)))
    }

    @Test fun xmpIsNotMistakenForExifAndAbsenceRequiresScanBoundary() {
        val header = bytes(255, 216, 255, 225, 0, 5, 88, 77, 80)
        assertEquals(JpegMetadataHeader.INCOMPLETE, inspectJpegMetadataHeader(header))
        assertEquals(JpegMetadataHeader.NO_EXIF, inspectJpegMetadataHeader(header + bytes(255, 218)))
    }

    @Test fun malformedLengthsAndNonJpegAreRejected() {
        assertEquals(JpegMetadataHeader.INVALID, inspectJpegMetadataHeader(bytes(137, 80, 78, 71)))
        assertEquals(JpegMetadataHeader.INVALID, inspectJpegMetadataHeader(bytes(255, 216, 255, 225, 0, 1)))
        assertEquals(JpegMetadataHeader.INCOMPLETE, inspectJpegMetadataHeader(bytes(255, 216, 255, 225, 255, 255)))
    }
}
