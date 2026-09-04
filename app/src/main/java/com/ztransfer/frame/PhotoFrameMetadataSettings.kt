@file:JvmName("AndroidPhotoFrameMetadataSettingsKt")

package com.ztransfer.frame

import java.time.LocalDate
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.format.DateTimeFormatter
import java.util.Locale

/** Android date-pattern example; locale and calendar formatting remain a platform concern. */
internal fun photoFrameDatePatternExample(pattern: String): String =
    formatPhotoFrameTemporalPattern(
        value = SAMPLE_CAPTURE_DATE_TIME,
        pattern = normalizePhotoFrameDatePattern(pattern),
    )

/** Android time-pattern example; locale and calendar formatting remain a platform concern. */
internal fun photoFrameTimePatternExample(pattern: String): String =
    formatPhotoFrameTemporalPattern(
        value = SAMPLE_CAPTURE_DATE_TIME,
        pattern = normalizePhotoFrameTimePattern(pattern),
    )

/** Supplies locale and clock values to the shared metadata-presentation policy. */
internal fun PhotoFrameMetadata.withPresentation(
    settings: PhotoFrameMetadataSettings,
    preview: Boolean = false,
    previewLocale: Locale = Locale.getDefault(),
): PhotoFrameMetadata {
    val normalized = normalizePhotoFrameMetadataSettings(settings)
    val previewAddressFallback = when {
        previewLocale.language.equals("zh", ignoreCase = true) &&
            (previewLocale.script.equals("Hant", ignoreCase = true) ||
                previewLocale.country.uppercase(Locale.ROOT) in setOf("TW", "HK", "MO")) ->
            "一個非常好的地方"
        previewLocale.language.equals("zh", ignoreCase = true) -> "一个非常好的地方"
        else -> "A very good place"
    }
    return withPhotoFrameMetadataPresentation(
        settings = normalized,
        preview = preview,
        previewAddressFallback = previewAddressFallback,
        formattedDateTime = formatPhotoFrameCaptureDateTime(
            value = dateTime,
            settings = normalized,
            preview = preview,
        ),
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
