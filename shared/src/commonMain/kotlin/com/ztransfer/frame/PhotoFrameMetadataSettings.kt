package com.ztransfer.frame

const val DEFAULT_PHOTO_FRAME_DATE_PATTERN = "yyyy-MM-dd"
const val DEFAULT_PHOTO_FRAME_TIME_PATTERN = "HH:mm:ss"

/** Preview-only values that make missing EXIF impossible to mistake for real camera data. */
const val PREVIEW_FAKE_BRAND = "NIKON"
const val PREVIEW_FAKE_MODEL = "Z 233"
const val PREVIEW_FAKE_LENS_MODEL = "1-800mm f/0.1"
const val PREVIEW_FAKE_FOCAL_LENGTH = "5100mm"
const val PREVIEW_FAKE_APERTURE = "f/0.1"
const val PREVIEW_FAKE_SHUTTER = "1/99999"
const val PREVIEW_FAKE_ISO = "ISO999999"
const val PREVIEW_FAKE_LATITUDE = 66.6666
const val PREVIEW_FAKE_LONGITUDE = 66.6666
const val PREVIEW_FAKE_ALTITUDE_METERS = 23333.0

/** Address reverse-geocoding remains disabled until a deterministic cross-platform policy exists. */
const val PHOTO_FRAME_ADDRESS_METADATA_ENABLED = false
val PHOTO_FRAME_DATE_PATTERNS = listOf(
    "yyyy-MM-dd",
    "yyyy/MM/dd",
    "yyyy.MM.dd",
    "MM-dd-yyyy",
)
val PHOTO_FRAME_TIME_PATTERNS = listOf("HH:mm", "HH:mm:ss", "HH.mm", "HH.mm.ss")

/** Per-preset metadata presentation. Missing map entries always fall back to preset defaults. */
data class PhotoFrameMetadataSettings(
    val showDate: Boolean,
    val showTime: Boolean,
    val showFocalLength: Boolean,
    val showExposure: Boolean,
    val showBrand: Boolean,
    val showModel: Boolean,
    val showLensModel: Boolean = false,
    val datePattern: String = DEFAULT_PHOTO_FRAME_DATE_PATTERN,
    val timePattern: String = DEFAULT_PHOTO_FRAME_TIME_PATTERN,
    val showAddress: Boolean = false,
    val showCoordinates: Boolean = false,
    val showAltitude: Boolean = false,
)

fun defaultPhotoFrameMetadataSettings(
    preset: PhotoFramePreset,
): PhotoFrameMetadataSettings = when (preset) {
    PhotoFramePreset.CLASSIC_SIGNATURE -> PhotoFrameMetadataSettings(
        showDate = false,
        showTime = false,
        showFocalLength = true,
        showExposure = true,
        showBrand = true,
        showModel = false,
        showLensModel = false,
    )
    PhotoFramePreset.GALLERY_MAT,
    PhotoFramePreset.FILM_EDGE -> PhotoFrameMetadataSettings(
        showDate = false,
        showTime = false,
        showFocalLength = false,
        showExposure = false,
        showBrand = false,
        showModel = false,
        showLensModel = false,
    )
    PhotoFramePreset.COLOR_ARCHIVE -> PhotoFrameMetadataSettings(
        showDate = false,
        showTime = false,
        showFocalLength = true,
        showExposure = true,
        showBrand = true,
        showModel = true,
        showLensModel = false,
    )
    PhotoFramePreset.FILM_GALLERY -> PhotoFrameMetadataSettings(
        showDate = true,
        showTime = true,
        showFocalLength = false,
        showExposure = false,
        showBrand = true,
        showModel = true,
        showLensModel = false,
    )
    else -> PhotoFrameMetadataSettings(
        showDate = preset == PhotoFramePreset.PLAQUE,
        showTime = preset == PhotoFramePreset.PLAQUE,
        showFocalLength = true,
        showExposure = true,
        showBrand = true,
        showModel = !preset.isBrandFrame(),
        showLensModel = false,
    )
}

fun resolvedPhotoFrameMetadataSettings(
    settings: Map<PhotoFramePreset, PhotoFrameMetadataSettings>,
    preset: PhotoFramePreset,
): PhotoFrameMetadataSettings = settings[preset]
    ?.let(::normalizePhotoFrameMetadataSettings)
    ?: defaultPhotoFrameMetadataSettings(preset)

fun normalizePhotoFrameMetadataSettings(
    settings: PhotoFrameMetadataSettings,
): PhotoFrameMetadataSettings = settings.copy(
    showAddress = settings.showAddress && PHOTO_FRAME_ADDRESS_METADATA_ENABLED,
    datePattern = normalizePhotoFrameDatePattern(settings.datePattern),
    timePattern = normalizePhotoFrameTimePattern(settings.timePattern),
)

/** Local-photo settings deliberately do not inherit camera-transfer location controls. */
fun PhotoFrameMetadataSettings.withoutLocationFields(): PhotoFrameMetadataSettings = copy(
    showAddress = false,
    showCoordinates = false,
    showAltitude = false,
)

fun normalizePhotoFrameDatePattern(pattern: String): String =
    pattern.trim().takeIf { it in PHOTO_FRAME_DATE_PATTERNS }
        ?: DEFAULT_PHOTO_FRAME_DATE_PATTERN

fun normalizePhotoFrameTimePattern(pattern: String): String =
    pattern.trim().takeIf { it in PHOTO_FRAME_TIME_PATTERNS }
        ?: DEFAULT_PHOTO_FRAME_TIME_PATTERN

/**
 * Applies platform-neutral visibility and fallback rules. The platform adapter supplies the
 * already-formatted date/time and locale-specific preview address so no clock or locale leaks in.
 */
fun PhotoFrameMetadata.withPhotoFrameMetadataPresentation(
    settings: PhotoFrameMetadataSettings,
    preview: Boolean,
    previewAddressFallback: String?,
    formattedDateTime: String?,
): PhotoFrameMetadata {
    val normalized = normalizePhotoFrameMetadataSettings(settings)
    val sourceMake = make?.trim()?.takeIf(String::isNotEmpty)
    val sourceModel = model?.trim()?.takeIf(String::isNotEmpty)
    val sourceLensModel = lensModel?.trim()?.takeIf(String::isNotEmpty)
    val inferredBrand = cameraBrandLabel(make, model).takeIf(String::isNotBlank)
    val sourceNormalizedModel = normalizeCameraModel(make, model).takeIf(String::isNotBlank)
    val hasCoordinates = latitude?.isFinite() == true && longitude?.isFinite() == true &&
        latitude != 0.0 && longitude != 0.0 &&
        latitude in -90.0..90.0 && longitude in -180.0..180.0
    val locationAddress = address?.trim()?.takeIf(String::isNotEmpty)
    val addressValue = when {
        !normalized.showAddress -> null
        locationAddress != null -> locationAddress
        preview -> previewAddressFallback
        else -> null
    }
    return copy(
        make = when {
            !normalized.showBrand -> null
            sourceMake != null -> sourceMake
            !normalized.showModel -> inferredBrand ?: PREVIEW_FAKE_BRAND.takeIf { preview }
            preview && inferredBrand != null -> inferredBrand
            preview -> PREVIEW_FAKE_BRAND
            else -> null
        },
        model = when {
            !normalized.showModel -> null
            !normalized.showBrand -> sourceNormalizedModel ?: PREVIEW_FAKE_MODEL.takeIf { preview }
            sourceModel != null -> sourceModel
            preview -> PREVIEW_FAKE_MODEL
            else -> null
        },
        aperture = when {
            !normalized.showExposure -> null
            !aperture.isNullOrBlank() -> aperture.trim()
            preview -> PREVIEW_FAKE_APERTURE
            else -> null
        },
        shutter = when {
            !normalized.showExposure -> null
            !shutter.isNullOrBlank() -> shutter.trim()
            preview -> PREVIEW_FAKE_SHUTTER
            else -> null
        },
        iso = when {
            !normalized.showExposure -> null
            !iso.isNullOrBlank() -> iso.trim()
            preview -> PREVIEW_FAKE_ISO
            else -> null
        },
        focalLength = when {
            !normalized.showFocalLength -> null
            !focalLength.isNullOrBlank() -> focalLength.trim()
            preview -> PREVIEW_FAKE_FOCAL_LENGTH
            else -> null
        },
        lensModel = when {
            !normalized.showLensModel -> null
            sourceLensModel != null -> sourceLensModel
            preview -> PREVIEW_FAKE_LENS_MODEL
            else -> null
        },
        address = addressValue,
        latitude = when {
            !normalized.showCoordinates -> null
            hasCoordinates -> latitude
            preview -> PREVIEW_FAKE_LATITUDE
            else -> null
        },
        longitude = when {
            !normalized.showCoordinates -> null
            hasCoordinates -> longitude
            preview -> PREVIEW_FAKE_LONGITUDE
            else -> null
        },
        altitudeMeters = when {
            !normalized.showAltitude -> null
            altitudeMeters?.takeIf { it.isFinite() && it != 0.0 } != null -> altitudeMeters
            preview -> PREVIEW_FAKE_ALTITUDE_METERS
            else -> null
        },
        dateTime = formattedDateTime.takeIf { normalized.showDate || normalized.showTime },
    )
}

private const val ENTRY_SEPARATOR = ";"
private const val FIELD_SEPARATOR = "|"

fun encodePhotoFrameMetadataSettings(
    settings: Map<PhotoFramePreset, PhotoFrameMetadataSettings>,
): String = PhotoFramePreset.entries.mapNotNull { preset ->
    val value = settings[preset]?.let(::normalizePhotoFrameMetadataSettings)
        ?: return@mapNotNull null
    if (value == defaultPhotoFrameMetadataSettings(preset)) return@mapNotNull null
    listOf(
        preset.name,
        value.showDate,
        value.showTime,
        value.showFocalLength,
        value.showExposure,
        value.showBrand,
        value.showModel,
        value.showLensModel,
        value.showCoordinates,
        value.showAltitude,
        value.datePattern,
        value.timePattern,
    ).joinToString(FIELD_SEPARATOR)
}.joinToString(ENTRY_SEPARATOR)

fun decodePhotoFrameMetadataSettings(
    encoded: String?,
): Map<PhotoFramePreset, PhotoFrameMetadataSettings> {
    if (encoded.isNullOrBlank()) return emptyMap()
    val restored = linkedMapOf<PhotoFramePreset, PhotoFrameMetadataSettings>()
    encoded.split(ENTRY_SEPARATOR).forEach { entry ->
        val fields = entry.split(FIELD_SEPARATOR)
        if (fields.size != 9 && fields.size != 10 && fields.size != 12 && fields.size != 13) {
            return@forEach
        }
        val preset = PhotoFramePreset.entries.firstOrNull { it.name == fields[0] }
            ?: return@forEach
        if (preset in restored) return@forEach
        val hasLensModel = fields.size >= 10
        val hasLocation = fields.size == 12 || fields.size == 13
        val hasLegacyAddressSlot = fields.size == 13
        val booleanEnd = when {
            fields.size == 13 -> 11
            fields.size == 12 -> 10
            hasLensModel -> 8
            else -> 7
        }
        val booleanFieldIndices = if (hasLegacyAddressSlot) {
            listOf(1, 2, 3, 4, 5, 6, 7, 9, 10)
        } else {
            (1 until booleanEnd).toList()
        }
        val booleans = booleanFieldIndices.map { fields[it].toBooleanStrictOrNull() }
        if (booleans.any { it == null }) return@forEach
        val value = normalizePhotoFrameMetadataSettings(
            PhotoFrameMetadataSettings(
                showDate = checkNotNull(booleans[0]),
                showTime = checkNotNull(booleans[1]),
                showFocalLength = checkNotNull(booleans[2]),
                showExposure = checkNotNull(booleans[3]),
                showBrand = checkNotNull(booleans[4]),
                showModel = checkNotNull(booleans[5]),
                showLensModel = if (hasLensModel) checkNotNull(booleans[6]) else false,
                showAddress = false,
                showCoordinates = if (hasLocation) checkNotNull(booleans[7]) else false,
                showAltitude = if (hasLocation) checkNotNull(booleans[8]) else false,
                datePattern = fields[booleanEnd],
                timePattern = fields[booleanEnd + 1],
            ),
        )
        if (value != defaultPhotoFrameMetadataSettings(preset)) restored[preset] = value
    }
    return restored
}

fun photoFrameMetadataSettingsFingerprintToken(
    preset: PhotoFramePreset,
    settings: PhotoFrameMetadataSettings,
): String? {
    val defaults = defaultPhotoFrameMetadataSettings(preset)
    val normalized = normalizePhotoFrameMetadataSettings(settings)
    val rendered = normalized.copy(
        datePattern = normalized.datePattern.takeIf { normalized.showDate }
            ?: defaults.datePattern,
        timePattern = normalized.timePattern.takeIf { normalized.showTime }
            ?: defaults.timePattern,
    )
    if (rendered == defaults) return null
    return encodePhotoFrameMetadataSettings(mapOf(preset to rendered)).takeIf(String::isNotEmpty)
}
