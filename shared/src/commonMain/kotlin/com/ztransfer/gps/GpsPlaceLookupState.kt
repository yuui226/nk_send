package com.ztransfer.gps

enum class GpsPlaceLookupStatus {
    IDLE,
    LOADING,
    SUCCESS,
    ERROR,
}

/** A one-shot lookup always keeps the exact coordinates that the user tapped. */
data class GpsPlaceLookupState(
    val latitude: Double? = null,
    val longitude: Double? = null,
    val status: GpsPlaceLookupStatus = GpsPlaceLookupStatus.IDLE,
    val placeName: String? = null,
)
