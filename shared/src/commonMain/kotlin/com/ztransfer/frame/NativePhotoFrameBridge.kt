package com.ztransfer.frame

/**
 * Scalar friendly entry point for Apple clients.
 *
 * The layout rules stay in common code so the eventual Swift renderer cannot
 * drift from Android's frame geometry.  The bridge deliberately returns the
 * existing immutable [PhotoFrameLayout] instead of exposing platform objects.
 */
object NativePhotoFrameBridge {
    /**
     * Resolves a persisted preset name and calculates its canvas/photo bounds.
     * Both enum names (for example `FILM_EDGE`) and stable file suffixes
     * (for example `film_edge`) are accepted. Unknown values return null so a
     * caller can keep the unframed export path without crashing.
     */
    fun layout(
        presetName: String,
        sourceWidth: Int,
        sourceHeight: Int,
        originalQuality: Boolean,
    ): PhotoFrameLayout? {
        val preset = resolvePreset(presetName) ?: return null
        return calculateLayout(preset, sourceWidth, sourceHeight, originalQuality)
    }

    fun isSupportedPreset(presetName: String): Boolean = resolvePreset(presetName) != null

    private fun resolvePreset(value: String): PhotoFramePreset? {
        val normalized = value.trim()
        return PhotoFramePreset.entries.firstOrNull {
            it.name.equals(normalized, ignoreCase = true) ||
                it.fileSuffix.equals(normalized, ignoreCase = true)
        }
    }

    private fun calculateLayout(
        preset: PhotoFramePreset,
        sourceWidth: Int,
        sourceHeight: Int,
        originalQuality: Boolean,
    ): PhotoFrameLayout = when {
        preset == PhotoFramePreset.PLAQUE && originalQuality ->
            calculateOriginalQualityPlaqueLayout(sourceWidth, sourceHeight)
        preset == PhotoFramePreset.PLAQUE ->
            calculatePlaqueFrameLayout(sourceWidth, sourceHeight)
        preset == PhotoFramePreset.IMMERSIVE && originalQuality ->
            PhotoFrameLayout(
                canvasWidth = sourceWidth,
                canvasHeight = sourceHeight,
                photoLeft = 0f,
                photoTop = 0f,
                photoRight = sourceWidth.toFloat(),
                photoBottom = sourceHeight.toFloat(),
                metadataTop = sourceHeight.toFloat(),
            )
        preset == PhotoFramePreset.IMMERSIVE ->
            calculateImmersiveFrameLayout(sourceWidth, sourceHeight)
        preset.isBrandFrame() && originalQuality ->
            calculateOriginalQualityBrandFrameLayout(sourceWidth, sourceHeight, preset)
        preset.isBrandFrame() ->
            calculateBrandFrameLayout(sourceWidth, sourceHeight, preset)
        preset.isEditorialFrame() && originalQuality ->
            calculateOriginalQualityEditorialFrameLayout(sourceWidth, sourceHeight, preset)
        preset.isEditorialFrame() ->
            calculateEditorialFrameLayout(sourceWidth, sourceHeight, preset)
        originalQuality ->
            calculateOriginalQualityPhotoFrameLayout(sourceWidth, sourceHeight)
        else ->
            calculatePhotoFrameLayout(sourceWidth, sourceHeight)
    }
}
