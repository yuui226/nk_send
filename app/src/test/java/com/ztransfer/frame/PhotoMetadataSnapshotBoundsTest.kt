package com.ztransfer.frame

import org.junit.Assert.*
import org.junit.Test

class PhotoMetadataSnapshotBoundsTest {
    private val normal = PhotoFrameMetadata("NIKON", "Z 30", "f/2.8", "1/100", "ISO100", "35mm",
        latitude = 24.5, longitude = 118.2)

    @Test fun normalSnapshotKeepsItsInstanceAndAllFields() {
        assertSame(normal, normal.boundedForQueue())
    }

    @Test fun oversizedExifTextIsBoundedWithoutBreakingUnicodeOrCoordinates() {
        val unusual = normal.copy(model = "a".repeat(255) + "\uD83D\uDCF7" + "b".repeat(1000),
            lensModel = "x".repeat(65000), city = "y".repeat(1000))
        val bounded = unusual.boundedForQueue()
        assertEquals(255, bounded.model!!.length)
        assertEquals(256, bounded.lensModel!!.length)
        assertEquals(256, bounded.city!!.length)
        assertEquals(normal.latitude, bounded.latitude)
        assertEquals(normal.longitude, bounded.longitude)
        assertEquals(normal.shutter, bounded.shutter)
    }
}
