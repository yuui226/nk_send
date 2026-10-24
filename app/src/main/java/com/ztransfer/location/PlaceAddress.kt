package com.ztransfer.location

/** Provider-neutral address fields. Null means that the provider did not supply this level. */
internal data class PlaceAddress(
    val locality: String?,
    val subLocality: String?,
    val subAdminArea: String?,
    val adminArea: String?,
    val countryCode: String?,
)

/** Displayable place names only: no coordinates, Android types or photo-effect settings. */
internal data class PlaceNames(val city: String?, val region: String?)
