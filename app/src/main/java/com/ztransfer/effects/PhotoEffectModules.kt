package com.ztransfer.effects

/** Visibility is independent of effect selection. At least one editor remains accessible. */
enum class PhotoEffectModule(val bit: Int) {
    FILTER(1), LUT(2), FRAME(4), WATERMARK(8);
}
const val ALL_PHOTO_EFFECT_MODULES = 15
fun normalizePhotoEffectModules(mask: Int): Int =
    (mask and ALL_PHOTO_EFFECT_MODULES).takeIf { it != 0 } ?: ALL_PHOTO_EFFECT_MODULES
fun Int.showsPhotoEffect(module: PhotoEffectModule): Boolean = this and module.bit != 0
private val FRAME_AND_WATERMARK = PhotoEffectModule.FRAME.bit or PhotoEffectModule.WATERMARK.bit

/** Free exports bind frame and watermark; Pro can expose either editor independently. */
fun effectivePhotoEffectModules(mask: Int, isPro: Boolean): Int {
    val normalized = normalizePhotoEffectModules(mask)
    return if (!isPro && normalized and FRAME_AND_WATERMARK != 0) normalized or FRAME_AND_WATERMARK
    else normalized
}

fun togglePhotoEffectModule(mask: Int, module: PhotoEffectModule, isPro: Boolean = true): Int {
    val current = effectivePhotoEffectModules(mask, isPro)
    val bits = if (!isPro && (module == PhotoEffectModule.FRAME || module == PhotoEffectModule.WATERMARK))
        FRAME_AND_WATERMARK else module.bit
    return (current xor bits).takeIf { it != 0 } ?: current
}
