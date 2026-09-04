package com.ztransfer.gps

/** User-facing GEO write cadence and its conservative phone-location sampling policy. */
enum class GpsUpdateFrequency(val seconds: Long) {
    THIRTY_SECONDS(30),
    ONE_MINUTE(60),
    TWO_MINUTES(120),
    FIVE_MINUTES(300),
    ;

    val intervalMillis: Long
        get() = seconds * 1_000L

    /** Keep a reasonably fresh GPS fix without polling at 5 s for every write cadence. */
    val gpsSamplingIntervalMillis: Long
        get() = when (this) {
            THIRTY_SECONDS -> 5_000L
            ONE_MINUTE -> 10_000L
            TWO_MINUTES -> 20_000L
            FIVE_MINUTES -> 30_000L
        }

    /** Network fixes remain less aggressive than GPS, with the same 30 s upper bound. */
    val networkSamplingIntervalMillis: Long
        get() = when (this) {
            THIRTY_SECONDS, ONE_MINUTE -> 15_000L
            TWO_MINUTES -> 20_000L
            FIVE_MINUTES -> 30_000L
        }

    companion object {
        const val PREFERENCE_KEY = "update_frequency_seconds"
        const val DEFAULT_SECONDS = 60L

        fun fromSeconds(seconds: Long): GpsUpdateFrequency =
            values().firstOrNull { it.seconds == seconds } ?: ONE_MINUTE
    }
}
