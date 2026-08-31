package com.ztransfer.frame

import java.time.LocalDate
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.format.DateTimeFormatter
import java.util.Locale

internal const val DEFAULT_PHOTO_FRAME_DATE_PATTERN = "yyyy-MM-dd"
internal const val DEFAULT_PHOTO_FRAME_TIME_PATTERN = "HH:mm:ss"
/**
 * Address reverse-geocoding in exported borders is intentionally disabled for now.  Keep the
 * setting field and decoder for forward compatibility so a future offline/online policy can
 * restore it without invalidating existing preference data.
 */
internal const val PHOTO_FRAME_ADDRESS_METADATA_ENABLED = false
internal val PHOTO_FRAME_DATE_PATTERNS = listOf("yyyy-MM-dd", "yyyy/MM/dd", "yyyy.MM.dd", "MM-dd-yyyy")
internal val PHOTO_FRAME_TIME_PATTERNS = listOf("HH:mm", "HH:mm:ss", "HH.mm", "HH.mm.ss")

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
    // Reserved for a future address policy; never trigger reverse geocoding during export.
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
    val hasCoordinates = latitude?.isFinite() == true && longitude?.isFinite() == true &&
        latitude != 0.0 && longitude != 0.0 &&
        latitude in -90.0..90.0 && longitude in -180.0..180.0
    val locationAddress = address?.trim()?.takeIf(String::isNotEmpty)
    val addressValue = when {
        !normalized.showAddress -> null
        locationAddress != null -> locationAddress
        !preview -> null
        previewLocale.language.equals("zh", ignoreCase = true) &&
            (previewLocale.script.equals("Hant", ignoreCase = true) ||
                previewLocale.country.uppercase(Locale.ROOT) in setOf("TW", "HK", "MO")) ->
            "一個非常好的地方"
        previewLocale.language.equals("zh", ignoreCase = true) -> "一个非常好的地方"
        else -> "A very good place"
    }
    return copy(
        make = when {
            !normalized.showBrand -> null
            !normalized.showModel && make.isNullOrBlank() ->
                cameraBrandLabel(make, model).takeIf(String::isNotBlank)
            else -> make
        },
        model = when {
            !normalized.showModel -> null
            !normalized.showBrand -> normalizeCameraModel(make, model)
            else -> model
        },
        aperture = aperture.takeIf { normalized.showExposure },
        shutter = shutter.takeIf { normalized.showExposure },
        iso = iso.takeIf { normalized.showExposure },
        focalLength = focalLength.takeIf { normalized.showFocalLength },
        lensModel = lensModel?.trim()?.takeIf(String::isNotEmpty)
            ?.takeIf { normalized.showLensModel },
        address = addressValue,
        latitude = when {
            !normalized.showCoordinates -> null
            hasCoordinates -> latitude
            preview -> 66.6666
            else -> null
        },
        longitude = when {
            !normalized.showCoordinates -> null
            hasCoordinates -> longitude
            preview -> 66.6666
            else -> null
        },
        altitudeMeters = when {
            !normalized.showAltitude -> null
            altitudeMeters?.takeIf { it.isFinite() && it != 0.0 } != null -> altitudeMeters
            preview -> 520.0
            else -> null
        },
        dateTime = formatPhotoFrameCaptureDateTime(dateTime, normalized),
    )
}

internal fun formatPhotoFrameCaptureDateTime(
    value: String?,
    settings: PhotoFrameMetadataSettings,
): String? {
    if (!settings.showDate && !settings.showTime) return null
    val parsed = parsePhotoFrameCaptureDateTime(value) ?: return null
    return buildList {
        if (settings.showDate) {
            add(formatPhotoFrameTemporalPattern(parsed, settings.datePattern))
        }
        if (settings.showTime && parsed.hasTime) {
            add(formatPhotoFrameTemporalPattern(parsed, settings.timePattern))
        }
    }.filter(String::isNotBlank).joinToString(" ").takeIf(String::isNotBlank)
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
        value.showAddress,
        value.showCoordinates,
        value.showAltitude,
        value.datePattern,
        value.timePattern,
    ).joinToString(FIELD_SEPARATOR)
}.joinToString(ENTRY_SEPARATOR)

internal fun decodePhotoFrameMetadataSettings(
    encoded: String?,
): Map<PhotoFramePreset, PhotoFrameMetadataSettings> {
    if (encoded.isNullOrBlank()) return emptyMap()
    val restored = linkedMapOf<PhotoFramePreset, PhotoFrameMetadataSettings>()
    encoded.split(ENTRY_SEPARATOR).forEach { entry ->
        val fields = entry.split(FIELD_SEPARATOR)
        // Older versions stored six or seven visibility flags. Accept those entries forever;
        // GPS visibility flags were appended in the current format and default to off.
        if (fields.size != 9 && fields.size != 10 && fields.size != 13) return@forEach
        val preset = PhotoFramePreset.entries.firstOrNull { it.name == fields[0] }
            ?: return@forEach
        if (preset in restored) return@forEach
        val hasLensModel = fields.size >= 10
        val hasLocation = fields.size == 13
        val booleanEnd = when {
            hasLocation -> 11
            hasLensModel -> 8
            else -> 7
        }
        val booleans = fields.subList(1, booleanEnd).map { it.toBooleanStrictOrNull() }
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
                showAddress = if (hasLocation) checkNotNull(booleans[7]) else false,
                showCoordinates = if (hasLocation) checkNotNull(booleans[8]) else false,
                showAltitude = if (hasLocation) checkNotNull(booleans[9]) else false,
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
