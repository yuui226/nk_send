package com.ztransfer.gps

import java.time.Instant
import java.time.ZoneOffset

/** Keeps the platform clock/conversion outside the shared binary codec. */
internal fun Instant.toGeoUtcDateTime(): GeoUtcDateTime {
    val utc = atZone(ZoneOffset.UTC)
    return GeoUtcDateTime(
        year = utc.year,
        month = utc.monthValue,
        day = utc.dayOfMonth,
        hour = utc.hour,
        minute = utc.minute,
        second = utc.second,
    )
}
