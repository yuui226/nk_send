package com.ztransfer.gps

import java.time.Instant
import org.junit.Assert.assertEquals
import org.junit.Test

class GeoUtcDateTimeAndroidTest {
    @Test
    fun convertsInstantToUtcFieldsForSharedCodec() {
        assertEquals(
            GeoUtcDateTime(2025, 1, 2, 3, 4, 5),
            Instant.parse("2025-01-02T03:04:05Z").toGeoUtcDateTime(),
        )
    }
}
