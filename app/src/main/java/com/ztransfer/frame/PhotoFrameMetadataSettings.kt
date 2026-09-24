package com.ztransfer.frame

import java.time.LocalDate
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.format.DateTimeFormatter
import java.util.Locale

internal const val DEFAULT_PHOTO_FRAME_DATE_PATTERN = "yyyy-MM-dd"
internal const val DEFAULT_PHOTO_FRAME_TIME_PATTERN = "HH:mm:ss"
/**
 * Deliberately absurd values used only while rendering the in-app preview.  They make it
 * impossible to mistake missing EXIF for real camera data.  Export always drops these values.
 */
internal const val PREVIEW_FAKE_BRAND = "NIKON"
internal const val PREVIEW_FAKE_MODEL = "Z 233"
internal const val PREVIEW_FAKE_LENS_MODEL = "1-800mm f/0.1"
internal const val PREVIEW_FAKE_FOCAL_LENGTH = "5100mm"
internal const val PREVIEW_FAKE_APERTURE = "f/0.1"
internal const val PREVIEW_FAKE_SHUTTER = "1/99999"
internal const val PREVIEW_FAKE_ISO = "ISO999999"
internal const val PREVIEW_FAKE_LATITUDE = 66.6666
internal const val PREVIEW_FAKE_LONGITUDE = 66.6666
internal const val PREVIEW_FAKE_ALTITUDE_METERS = 23333.0
/**
 * The legacy full street-address field stays disabled. City/district have separate opt-in flags
 * and pass through the shared connection policy before presentation.
 */
internal const val PHOTO_FRAME_ADDRESS_METADATA_ENABLED = false
internal val PHOTO_FRAME_DATE_PATTERNS = listOf("yyyy-MM-dd", "yyyy/MM/dd", "yyyy.MM.dd", "MM-dd-yyyy")
internal val PHOTO_FRAME_TIME_PATTERNS = listOf("HH:mm", "HH:mm:ss", "HH.mm", "HH.mm.ss")

enum class PhotoFrameBrandStyle { TEXT, LOGO }

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
    val showCity: Boolean = false,
    val showRegion: Boolean = false,
    val brandStyle: PhotoFrameBrandStyle = PhotoFrameBrandStyle.TEXT,
)

internal fun defaultPhotoFrameMetadataSettings(
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
        // Existing defaults stay pixel-identical; lens is opt-in on every legacy frame.
        showLensModel = false,
    )
}

internal fun resolvedPhotoFrameMetadataSettings(
    settings: Map<PhotoFramePreset, PhotoFrameMetadataSettings>,
    preset: PhotoFramePreset,
): PhotoFrameMetadataSettings = settings[preset]
    ?.let(::normalizePhotoFrameMetadataSettings)
    ?: defaultPhotoFrameMetadataSettings(preset)

internal fun normalizePhotoFrameMetadataSettings(
    settings: PhotoFrameMetadataSettings,
): PhotoFrameMetadataSettings = settings.copy(
    // Never restore the old full street-address option.
    showAddress = settings.showAddress && PHOTO_FRAME_ADDRESS_METADATA_ENABLED,
    datePattern = normalizePhotoFrameDatePattern(settings.datePattern),
    timePattern = normalizePhotoFrameTimePattern(settings.timePattern),
)

/**
 * The local-photo workbench predates location metadata controls. Keep its settings independent
 * from the camera-transfer editor by explicitly removing the three location fields there.
 */
internal fun PhotoFrameMetadataSettings.withoutLocationFields(): PhotoFrameMetadataSettings = copy(
    showAddress = false,
    showCity = false,
    showRegion = false,
    showCoordinates = false,
    showAltitude = false,
)

internal fun normalizePhotoFrameDatePattern(pattern: String): String =
    pattern.trim().takeIf { it in PHOTO_FRAME_DATE_PATTERNS }
        ?: DEFAULT_PHOTO_FRAME_DATE_PATTERN

internal fun normalizePhotoFrameTimePattern(pattern: String): String =
    pattern.trim().takeIf { it in PHOTO_FRAME_TIME_PATTERNS }
        ?: DEFAULT_PHOTO_FRAME_TIME_PATTERN

internal fun photoFrameDatePatternExample(pattern: String): String =
    formatPhotoFrameTemporalPattern(
        value = SAMPLE_CAPTURE_DATE_TIME,
        pattern = normalizePhotoFrameDatePattern(pattern),
    )

internal fun photoFrameTimePatternExample(pattern: String): String =
    formatPhotoFrameTemporalPattern(
        value = SAMPLE_CAPTURE_DATE_TIME,
        pattern = normalizePhotoFrameTimePattern(pattern),
    )

internal fun PhotoFrameMetadata.withPresentation(
    settings: PhotoFrameMetadataSettings,
    preview: Boolean = false,
    previewLocale: Locale = Locale.getDefault(),
): PhotoFrameMetadata {
    val normalized = normalizePhotoFrameMetadataSettings(settings)
    val sourceMake = make?.trim()?.takeIf(String::isNotEmpty)
    val sourceModel = model?.trim()?.takeIf(String::isNotEmpty)
    val sourceLensModel = lensModel?.trim()?.takeIf(String::isNotEmpty)
    val inferredBrand = cameraBrandLabel(make, model).takeIf(String::isNotBlank)
    val sourceNormalizedModel = normalizeCameraModel(make, model)
        .takeIf(String::isNotBlank)
    val hasCoordinates = validFrameCoordinates(latitude, longitude)
    val previewPlace = if (preview) {
        when {
            previewLocale.language != "zh" -> "Light & Shadow City" to "Blue Hour District"
            previewLocale.script == "Hant" || previewLocale.country in setOf("TW", "HK", "MO") ->
                "光影市" to "藍調區"
            else -> "光影市" to "蓝调区"
        }
    } else null
    return copy(
        brandStyle = normalized.brandStyle,
        make = when {
            !normalized.showBrand -> null
            sourceMake != null -> sourceMake
            normalized.brandStyle == PhotoFrameBrandStyle.LOGO && inferredBrand != null -> inferredBrand
            // Preserve export presentation: model-derived brand fallback was historically only
            // materialized when the model row was hidden. Preview may also use that real inference
            // before falling back to the deliberately fake brand.
            !normalized.showModel -> inferredBrand
                ?: PREVIEW_FAKE_BRAND.takeIf { preview }
            preview && inferredBrand != null -> inferredBrand
            preview -> PREVIEW_FAKE_BRAND
            else -> null
        },
        model = when {
            !normalized.showModel -> null
            !normalized.showBrand -> sourceNormalizedModel
                ?: PREVIEW_FAKE_MODEL.takeIf { preview }
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
        address = null,
        city = if (normalized.showCity) {
            city?.trim()?.takeIf(String::isNotEmpty) ?: previewPlace?.first
        } else null,
        region = if (normalized.showRegion) {
            region?.trim()?.takeIf(String::isNotEmpty) ?: previewPlace?.second
        } else null,
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
        dateTime = formatPhotoFrameCaptureDateTime(dateTime, normalized, preview = preview),
    )
}

internal fun formatPhotoFrameCaptureDateTime(
    value: String?,
    settings: PhotoFrameMetadataSettings,
    preview: Boolean = false,
): String? {
    if (!settings.showDate && !settings.showTime) return null
    val parsed = parsePhotoFrameCaptureDateTime(value)
    val fallbackDate = if (preview) LocalDate.now().plusDays(1) else null
    val date = when {
        !settings.showDate -> null
        parsed != null -> formatPhotoFrameTemporalPattern(parsed, settings.datePattern)
        fallbackDate != null -> formatPhotoFrameTemporalPattern(
            fallbackDate.atStartOfDay(),
            settings.datePattern,
        )
        else -> null
    }
    val time = when {
        !settings.showTime -> null
        parsed?.hasTime == true -> formatPhotoFrameTemporalPattern(parsed, settings.timePattern)
        preview -> previewFakeTime(settings.timePattern)
        else -> null
    }
    return buildList {
        date?.takeIf(String::isNotBlank)?.let(::add)
        time?.takeIf(String::isNotBlank)?.let(::add)
    }.filter(String::isNotBlank).joinToString(" ").takeIf(String::isNotBlank)
}

/** Invalid-on-purpose clock values used only for the preview fallback. */
private fun previewFakeTime(pattern: String): String = when (
    normalizePhotoFrameTimePattern(pattern)
) {
    "HH:mm" -> "25:61"
    "HH.mm" -> "25.61"
    "HH.mm.ss" -> "25.61.61"
    else -> "25:61:61"
}

private data class ParsedCaptureDateTime(
    val date: LocalDate,
    val time: LocalTime?,
) {
    val hasTime: Boolean get() = time != null
    val dateTime: LocalDateTime get() = LocalDateTime.of(date, time ?: LocalTime.MIDNIGHT)
}

private fun parsePhotoFrameCaptureDateTime(value: String?): ParsedCaptureDateTime? {
    val normalized = normalizeCaptureDateTime(value) ?: return null
    val date = runCatching { LocalDate.parse(normalized.take(10)) }.getOrNull() ?: return null
    val time = normalized.drop(10).trim().takeIf(String::isNotEmpty)?.let { raw ->
        runCatching { LocalTime.parse(raw.take(8)) }.getOrNull()
    }
    return ParsedCaptureDateTime(date, time)
}

private fun formatPhotoFrameTemporalPattern(
    value: LocalDateTime,
    pattern: String,
): String = value.format(DateTimeFormatter.ofPattern(pattern, Locale.US))

private fun formatPhotoFrameTemporalPattern(
    value: ParsedCaptureDateTime,
    pattern: String,
): String = formatPhotoFrameTemporalPattern(value.dateTime, pattern)

private val SAMPLE_CAPTURE_DATE_TIME: LocalDateTime =
    LocalDateTime.of(2026, 8, 17, 14, 32, 8)

private const val ENTRY_SEPARATOR = ";"
private const val FIELD_SEPARATOR = "|"

internal fun encodePhotoFrameMetadataSettings(
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
    ).let { fields ->
        when {
            value.brandStyle == PhotoFrameBrandStyle.LOGO -> fields + listOf(value.showCity, value.showRegion, value.brandStyle.name)
            value.showCity || value.showRegion -> fields + listOf(value.showCity, value.showRegion)
            else -> fields
        }
    }.joinToString(FIELD_SEPARATOR)
}.joinToString(ENTRY_SEPARATOR)

internal fun decodePhotoFrameMetadataSettings(
    encoded: String?,
): Map<PhotoFramePreset, PhotoFrameMetadataSettings> {
    if (encoded.isNullOrBlank()) return emptyMap()
    val restored = linkedMapOf<PhotoFramePreset, PhotoFrameMetadataSettings>()
    encoded.split(ENTRY_SEPARATOR).forEach { entry ->
        val fields = entry.split(FIELD_SEPARATOR)
        // Older versions stored six or seven visibility flags. Accept those entries forever;
        // the former 13-field location format had an address slot which is deliberately skipped.
        // 14-field entries append city/district; 15-field entries append brand style.
        if (fields.size != 9 && fields.size != 10 && fields.size != 12 && fields.size != 13 && fields.size != 14 && fields.size != 15) {
            return@forEach
        }
        val preset = PhotoFramePreset.entries.firstOrNull { it.name == fields[0] }
            ?: return@forEach
        if (preset in restored) return@forEach
        val hasLensModel = fields.size >= 10
        val hasLocation = fields.size >= 12
        val hasLegacyAddressSlot = fields.size == 13
        val booleanEnd = when {
            fields.size == 13 -> 11
            fields.size == 12 || fields.size >= 14 -> 10
            hasLensModel -> 8
            else -> 7
        }
        // A legacy 13-field entry stores address at index 8.  Omit that token entirely instead
        // of parsing it; coordinates and altitude then line up with the current nine-flag model.
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
                brandStyle = if (fields.size == 15) PhotoFrameBrandStyle.entries.firstOrNull { it.name == fields[14] } ?: return@forEach else PhotoFrameBrandStyle.TEXT,
                showModel = checkNotNull(booleans[5]),
                showLensModel = if (hasLensModel) checkNotNull(booleans[6]) else false,
                // Address was removed from the border feature; retain only coordinate/altitude.
                showAddress = false,
                showCity = if (fields.size >= 14) fields[12].toBooleanStrictOrNull() ?: return@forEach else false,
                showRegion = if (fields.size >= 14) fields[13].toBooleanStrictOrNull() ?: return@forEach else false,
                showCoordinates = if (hasLocation) {
                    checkNotNull(booleans[7])
                } else false,
                showAltitude = if (hasLocation) {
                    checkNotNull(booleans[8])
                } else false,
                datePattern = fields[booleanEnd],
                timePattern = fields[booleanEnd + 1],
            )
        )
        if (value != defaultPhotoFrameMetadataSettings(preset)) restored[preset] = value
    }
    return restored
}

internal fun photoFrameMetadataSettingsFingerprintToken(
    preset: PhotoFramePreset,
    settings: PhotoFrameMetadataSettings,
): String? {
    val defaults = defaultPhotoFrameMetadataSettings(preset)
    val normalized = normalizePhotoFrameMetadataSettings(settings)
    // Hidden format choices are remembered for the next time the field is enabled, but they do
    // not change pixels and therefore must not create a different output name.
    val rendered = normalized.copy(
        datePattern = normalized.datePattern.takeIf { normalized.showDate }
            ?: defaults.datePattern,
        timePattern = normalized.timePattern.takeIf { normalized.showTime }
            ?: defaults.timePattern,
    )
    if (rendered == defaults) return null
    return encodePhotoFrameMetadataSettings(mapOf(preset to rendered)).takeIf(String::isNotEmpty)
}

/** Brand button: off → text → logo → off. */
internal fun PhotoFrameMetadataSettings.nextBrandStyle(): PhotoFrameMetadataSettings = when {
    !showBrand -> copy(showBrand = true, brandStyle = PhotoFrameBrandStyle.TEXT)
    brandStyle == PhotoFrameBrandStyle.TEXT -> copy(brandStyle = PhotoFrameBrandStyle.LOGO)
    else -> copy(showBrand = false, brandStyle = PhotoFrameBrandStyle.TEXT)
}
