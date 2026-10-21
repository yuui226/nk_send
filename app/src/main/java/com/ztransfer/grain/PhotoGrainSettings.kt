package com.ztransfer.grain

import java.util.Locale

/** Stable preference and native identifiers; do not persist enum ordinals. */
enum class PhotoGrainStyle(val id: String, val nativeId: Int, val defaultIntensityPercent: Int) {
    FINE("fine", 0, 50),
    MEDIUM("medium", 1, 40),
    COARSE("coarse", 2, 30);

    companion object {
        fun fromId(id: String?): PhotoGrainStyle = entries.firstOrNull { it.id == id } ?: FINE
    }
}

/** A finishing effect independent of the selected colour filter or LUT. */
data class PhotoGrainSettings(
    val intensityPercent: Int = PhotoGrainStyle.FINE.defaultIntensityPercent,
    val enabled: Boolean = false,
    val style: PhotoGrainStyle = PhotoGrainStyle.FINE,
) {
    fun normalized(): PhotoGrainSettings = copy(intensityPercent = intensityPercent.coerceIn(0, 100))

    val isEnabled: Boolean get() = enabled && intensityPercent.coerceIn(0, 100) > 0

    /** Apply wheel actions to the current draft, never a snapshot from an earlier composition. */
    fun selectStyle(
        selectedStyle: PhotoGrainStyle?,
        rememberedIntensities: Map<PhotoGrainStyle, Int>,
    ): PhotoGrainSettings {
        val current = normalized()
        if (selectedStyle == null) return current.copy(enabled = false)
        return current.copy(
            enabled = true,
            style = selectedStyle,
            intensityPercent = if (selectedStyle == current.style) current.intensityPercent else
                (rememberedIntensities[selectedStyle] ?: selectedStyle.defaultIntensityPercent).coerceIn(0, 100),
        )
    }

    /** A late release from a disabled/previous style's wheel must not edit the new selection. */
    fun changeIntensity(forStyle: PhotoGrainStyle, intensity: Int): PhotoGrainSettings =
        if (!enabled || style != forStyle) this else copy(intensityPercent = intensity.coerceIn(0, 100))

    companion object {
        val OFF = PhotoGrainSettings()
    }
}

/** Editor history is independent from the immutable recipe captured by a queued photo. */
fun normalizedPhotoGrainIntensities(
    values: Map<PhotoGrainStyle, Int> = emptyMap(),
): Map<PhotoGrainStyle, Int> = PhotoGrainStyle.entries.associateWith { style ->
    (values[style] ?: style.defaultIntensityPercent).coerceIn(0, 100)
}

/** Include only for enabled grain; OFF must retain existing output identities. */
const val PHOTO_GRAIN_RENDER_VERSION = 1

/** Stable across previews, retries, storage paths and filename casing. Never uses time or handles. */
fun photoGrainSeed(sourceName: String): Int {
    val name = sourceName.substringAfterLast('/').substringAfterLast('\\').lowercase(Locale.ROOT)
    var hash = 0x811c9dc5.toInt()
    for (byte in name.toByteArray(Charsets.UTF_8)) {
        hash = (hash xor (byte.toInt() and 0xff)) * 0x01000193
    }
    return hash
}
