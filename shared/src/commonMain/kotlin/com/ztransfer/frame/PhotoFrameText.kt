package com.ztransfer.frame

import com.ztransfer.format.formatDecimalDegreeCoordinatesText

fun normalizeCameraMake(make: String?): String {
    val value = make?.trim().orEmpty()
    return when {
        value.contains("nikon", ignoreCase = true) -> "Nikon"
        value.contains("canon", ignoreCase = true) -> "Canon"
        value.contains("sony", ignoreCase = true) -> "SONY"
        value.contains("fujifilm", ignoreCase = true) -> "FUJIFILM"
        value.contains("hasselblad", ignoreCase = true) -> "Hasselblad"
        value.contains("leica", ignoreCase = true) -> "Leica"
        value.contains("panasonic", ignoreCase = true) -> "Panasonic"
        value.contains("olympus", ignoreCase = true) ||
            value.contains("om digital", ignoreCase = true) -> "OM SYSTEM"
        value.contains("pentax", ignoreCase = true) -> "PENTAX"
        value.contains("ricoh", ignoreCase = true) -> "RICOH"
        value.contains("apple", ignoreCase = true) -> "Apple"
        value.contains("samsung", ignoreCase = true) -> "SAMSUNG"
        value.contains("google", ignoreCase = true) -> "Google"
        value.contains("xiaomi", ignoreCase = true) ||
            value.contains("redmi", ignoreCase = true) -> "XIAOMI"
        value.contains("huawei", ignoreCase = true) -> "HUAWEI"
        value.contains("honor", ignoreCase = true) -> "HONOR"
        value.contains("oneplus", ignoreCase = true) -> "ONEPLUS"
        value.contains("oppo", ignoreCase = true) -> "OPPO"
        value.contains("vivo", ignoreCase = true) -> "VIVO"
        value.contains("realme", ignoreCase = true) -> "REALME"
        value.contains("motorola", ignoreCase = true) -> "MOTOROLA"
        value.isNotEmpty() -> value
        else -> ""
    }
}

/** Uppercase typographic brand used by the brand-frame presets; no trademark artwork. */
fun cameraBrandLabel(make: String?, model: String?): String {
    val normalizedMake = normalizeCameraMake(make).trim()
    if (normalizedMake.isNotEmpty()) return normalizedMake.uppercase().take(32)
    val modelValue = model?.trim().orEmpty()
    return when {
        modelValue.contains("nikon", ignoreCase = true) -> "NIKON"
        modelValue.contains("canon", ignoreCase = true) -> "CANON"
        modelValue.contains("sony", ignoreCase = true) -> "SONY"
        modelValue.contains("fujifilm", ignoreCase = true) -> "FUJIFILM"
        modelValue.contains("hasselblad", ignoreCase = true) -> "HASSELBLAD"
        modelValue.contains("leica", ignoreCase = true) -> "LEICA"
        modelValue.contains("panasonic", ignoreCase = true) -> "PANASONIC"
        modelValue.contains("olympus", ignoreCase = true) ||
            modelValue.contains("om system", ignoreCase = true) -> "OM SYSTEM"
        modelValue.contains("pentax", ignoreCase = true) -> "PENTAX"
        modelValue.contains("ricoh", ignoreCase = true) -> "RICOH"
        modelValue.contains("iphone", ignoreCase = true) -> "APPLE"
        modelValue.contains("pixel", ignoreCase = true) -> "GOOGLE"
        modelValue.contains("galaxy", ignoreCase = true) ||
            modelValue.startsWith("SM-", ignoreCase = true) -> "SAMSUNG"
        modelValue.contains("xiaomi", ignoreCase = true) ||
            modelValue.contains("redmi", ignoreCase = true) -> "XIAOMI"
        modelValue.contains("huawei", ignoreCase = true) -> "HUAWEI"
        modelValue.contains("honor", ignoreCase = true) -> "HONOR"
        modelValue.contains("oneplus", ignoreCase = true) -> "ONEPLUS"
        modelValue.contains("oppo", ignoreCase = true) -> "OPPO"
        modelValue.contains("vivo", ignoreCase = true) -> "VIVO"
        modelValue.contains("realme", ignoreCase = true) -> "REALME"
        else -> ""
    }
}

fun normalizeCameraModel(make: String?, model: String?): String {
    val value = model?.trim().orEmpty()
    if (value.isEmpty()) return ""
    val brand = normalizeCameraMake(make)
    val prefixes = buildList {
        make?.trim()?.takeIf { it.isNotEmpty() }?.let(::add)
        if (brand.isNotEmpty()) add(brand)
    }.distinctBy { it.lowercase() }
        .sortedByDescending(String::length)
    val prefix = prefixes.firstOrNull { value.startsWith(it, ignoreCase = true) } ?: return value
    return value.substring(prefix.length).trimStart(' ', '-', '_')
}

fun frameDetailLine(metadata: PhotoFrameMetadata): String =
    listOfNotNull(
        metadata.focalLength,
        metadata.aperture?.replace("f/", "F", ignoreCase = true),
        metadata.shutter?.let { if (it.endsWith("s", ignoreCase = true)) it else "${it}s" },
        metadata.iso,
    ).joinToString("   ")

/** Locale-specific fixed-decimal rendering stays in the platform adapter. */
fun frameLocationRows(
    metadata: PhotoFrameMetadata,
    renderFixedDecimal: (value: Double, fractionDigits: Int) -> String,
): List<String> = buildList {
    val coordinates = if (
        metadata.latitude?.isFinite() == true && metadata.longitude?.isFinite() == true &&
        metadata.latitude != 0.0 && metadata.longitude != 0.0 &&
        metadata.latitude in -90.0..90.0 && metadata.longitude in -180.0..180.0
    ) {
        formatDecimalDegreeCoordinatesText(
            latitude = metadata.latitude,
            longitude = metadata.longitude,
            fractionDigits = 4,
            renderFixedDecimal = renderFixedDecimal,
        )
    } else {
        null
    }
    val altitude = metadata.altitudeMeters
        ?.takeIf { it.isFinite() && it != 0.0 }
        ?.let { "${renderFixedDecimal(it, 0)}m" }
    listOfNotNull(coordinates, altitude)
        .joinToString("  ")
        .takeIf(String::isNotBlank)
        ?.let(::add)
}

fun immersiveFrameDetailLine(metadata: PhotoFrameMetadata): String =
    listOfNotNull(
        metadata.focalLength,
        metadata.aperture?.let {
            if (it.startsWith("f/", ignoreCase = true)) it.lowercase() else "f/$it"
        },
        metadata.shutter?.let { if (it.endsWith("s", ignoreCase = true)) it else "${it}s" },
        metadata.iso,
    ).joinToString("  ")

fun normalizeCaptureDateTime(value: String?): String? {
    val trimmed = value?.trim()?.takeIf(String::isNotEmpty) ?: return null
    val isExifDate =
        trimmed.length >= 10 &&
            trimmed[4] == ':' &&
            trimmed[7] == ':' &&
            trimmed.substring(0, 4).all(Char::isDigit) &&
            trimmed.substring(5, 7).all(Char::isDigit) &&
            trimmed.substring(8, 10).all(Char::isDigit)
    return if (isExifDate) {
        buildString(trimmed.length) {
            append(trimmed, 0, 4)
            append('-')
            append(trimmed, 5, 7)
            append('-')
            append(trimmed.substring(8))
        }
    } else {
        trimmed
    }
}

fun normalizeIso(value: String?): String? {
    val firstValue = value?.substringBefore(',')?.trim().orEmpty()
    if (firstValue.isEmpty()) return null
    val withoutPrefix = if (firstValue.startsWith("ISO", ignoreCase = true)) {
        firstValue.substring(3).trimStart(' ', ':')
    } else {
        firstValue
    }
    return withoutPrefix.takeIf { it.isNotEmpty() }?.let { "ISO$it" }
}

fun formatApertureText(
    value: Double,
    renderFixedDecimal: (value: Double, fractionDigits: Int) -> String,
): String = if (value % 1.0 < 0.05) {
    "f/${renderFixedDecimal(value, 0)}"
} else {
    "f/${renderFixedDecimal(value, 1)}"
}

fun formatShutterText(
    seconds: Double,
    renderFixedDecimal: (value: Double, fractionDigits: Int) -> String,
): String = when {
    seconds >= 1.0 -> if (seconds % 1.0 < 0.05) {
        "${renderFixedDecimal(seconds, 0)}s"
    } else {
        "${renderFixedDecimal(seconds, 1)}s"
    }
    seconds >= 0.4 -> "${renderFixedDecimal(seconds, 1)}s"
    seconds > 0.0 -> "1/${renderFixedDecimal(1.0 / seconds, 0)}"
    else -> ""
}
