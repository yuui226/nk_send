package com.ztransfer.frame

import com.ztransfer.location.PlaceAddress
import com.ztransfer.location.PlaceAddressMapper
import com.ztransfer.location.PlaceNames

/** Photo-facing name retained so rendering and deduplication share the same immutable value. */
internal typealias FramePlace = PlaceNames

/** Compatibility entry point; all geographical decisions live in the location module. */
internal fun framePlace(
    city: String?,
    district: String?,
    subAdmin: String?,
    admin: String?,
    countryCode: String? = null,
): FramePlace = PlaceAddressMapper.resolve(PlaceAddress(city, district, subAdmin, admin, countryCode))
