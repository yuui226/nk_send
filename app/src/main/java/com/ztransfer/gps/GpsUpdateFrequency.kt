package com.ztransfer.gps

/** User-facing GEO write cadence. Location providers keep their own sampling cadence. */
enum class GpsUpdateFrequency(val seconds: Long) {
    THIRTY_SECONDS(30),
    ONE_MINUTE(60),
    TWO_MINUTES(120),
    FIVE_MINUTES(300),
    ;

    val intervalMillis: Long
        get() = seconds * 1_000L

    companion object {
        const val PREFERENCE_KEY = "update_frequency_seconds"
        const val DEFAULT_SECONDS = 60L

        fun fromSeconds(seconds: Long): GpsUpdateFrequency =
            values().firstOrNull { it.seconds == seconds } ?: ONE_MINUTE
    }
}
