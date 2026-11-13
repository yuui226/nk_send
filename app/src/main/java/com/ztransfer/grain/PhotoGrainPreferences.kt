package com.ztransfer.grain

import android.content.SharedPreferences

/** The editor remembers every style, while only [settings] belongs to a render recipe. */
data class PhotoGrainPreferenceState(
    val settings: PhotoGrainSettings,
    val intensities: Map<PhotoGrainStyle, Int>,
)

/** Pure recovery path shared by the two independent preference namespaces. */
internal fun restorePhotoGrainPreferences(
    values: Map<String, *>,
    prefix: String,
    allowEnabled: Boolean = true,
): PhotoGrainPreferenceState {
    val legacyIntensity = grainIntensity(values["${prefix}_intensity"])
    val style = PhotoGrainStyle.fromId(values["${prefix}_style"] as? String)
    val intensities = PhotoGrainStyle.entries.associateWith { entry ->
        grainIntensity(values[grainIntensityKey(prefix, entry)])
            ?: legacyIntensity.takeIf { entry == PhotoGrainStyle.FINE }
            ?: entry.defaultIntensityPercent
    }
    // Only old intensity-only versions infer an enabled switch. A missing/corrupt switch in
    // the new format must not unexpectedly turn a previously disabled effect on.
    val hasStylePreferences = "${prefix}_style" in values || PhotoGrainStyle.entries.any {
        grainIntensityKey(prefix, it) in values
    }
    val enabled = values["${prefix}_enabled"] as? Boolean
        ?: ("${prefix}_enabled" !in values && !hasStylePreferences &&
            legacyIntensity != null && legacyIntensity > 0)
    return PhotoGrainPreferenceState(
        PhotoGrainSettings(intensities.getValue(style), enabled && allowEnabled, style),
        intensities,
    )
}

/** Current recipe wins for its own style; changing another style's memory never selects it. */
internal fun normalizedPhotoGrainPreferenceState(
    settings: PhotoGrainSettings,
    intensities: Map<PhotoGrainStyle, Int>,
): PhotoGrainPreferenceState {
    val normalized = settings.normalized()
    return PhotoGrainPreferenceState(
        normalized,
        normalizedPhotoGrainIntensities(intensities) +
            (normalized.style to normalized.intensityPercent),
    )
}

private fun grainIntensityKey(prefix: String, style: PhotoGrainStyle): String =
    "${prefix}_intensity_${style.id}"

private fun grainIntensity(value: Any?): Int? {
    val number = when (value) {
        is Byte -> value.toLong()
        is Short -> value.toLong()
        is Int -> value.toLong()
        is Long -> value
        is String -> value.trim().toLongOrNull()
        else -> null
    } ?: return null
    return number.coerceIn(0L, 100L).toInt()
}

/** Works with the existing camera/local preference files instead of adding a shared global store. */
class PhotoGrainPreferences(
    private val preferences: SharedPreferences,
    private val prefix: String,
) {
    fun load(allowEnabled: Boolean = true): PhotoGrainPreferenceState {
        val previous = preferences.all
        val restored = restorePhotoGrainPreferences(previous, prefix, allowEnabled)
        val canonical = preferenceValues(restored)
        if (canonical.any { (key, value) -> previous[key] != value }) {
            writeValues(preferences.edit(), canonical).apply()
        }
        return restored
    }

    fun save(
        settings: PhotoGrainSettings,
        intensities: Map<PhotoGrainStyle, Int>,
    ): PhotoGrainPreferenceState {
        val state = normalizedPhotoGrainPreferenceState(settings, intensities)
        writeValues(preferences.edit(), preferenceValues(state)).apply()
        return state
    }

    /** Lets the phone editor save grain atomically with the rest of its controls. */
    fun writeTo(
        editor: SharedPreferences.Editor,
        settings: PhotoGrainSettings,
        intensities: Map<PhotoGrainStyle, Int>,
    ) {
        writeValues(editor, preferenceValues(normalizedPhotoGrainPreferenceState(settings, intensities)))
    }

    /** A draft wheel detent remembers only this style, without committing the selected recipe. */
    fun rememberIntensity(style: PhotoGrainStyle, intensityPercent: Int) {
        val intensity = intensityPercent.coerceIn(0, 100)
        preferences.edit().apply {
            putInt(grainIntensityKey(prefix, style), intensity)
            if (style == PhotoGrainStyle.FINE) putInt("${prefix}_intensity", intensity)
        }.apply()
    }

    private fun preferenceValues(state: PhotoGrainPreferenceState): Map<String, Any> = buildMap {
        put("${prefix}_style", state.settings.style.id)
        put("${prefix}_enabled", state.settings.enabled)
        // The legacy single style was fine; retain its remembered value for old versions.
        put("${prefix}_intensity", state.intensities.getValue(PhotoGrainStyle.FINE))
        for ((style, intensity) in state.intensities) put(grainIntensityKey(prefix, style), intensity)
    }

    private fun writeValues(
        editor: SharedPreferences.Editor,
        values: Map<String, Any>,
    ): SharedPreferences.Editor = editor.apply {
        for ((key, value) in values) when (value) {
            is Int -> putInt(key, value)
            is Boolean -> putBoolean(key, value)
            is String -> putString(key, value)
        }
    }
}
