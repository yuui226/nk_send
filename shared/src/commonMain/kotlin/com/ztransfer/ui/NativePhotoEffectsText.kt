package com.ztransfer.ui

data class NativePhotoEffectsHelpText(
    val dialHint: String,
    val longPressHint: String,
)

/** Shared wording for the two photo-effects dials on Android and iOS. */
object NativePhotoEffectsText {
    fun forLanguage(languageTag: String): NativePhotoEffectsHelpText {
        val tag = languageTag.lowercase().replace('_', '-')
        if (!tag.startsWith("zh")) {
            return NativePhotoEffectsHelpText(
                dialHint = "Dial: hold and drag up or down to adjust quickly",
                longPressHint = "Hold the photo filter dial: choose by category",
            )
        }
        val traditional = "hant" in tag || tag.endsWith("-tw") || tag.endsWith("-hk") || tag.endsWith("-mo")
        return if (traditional) {
            NativePhotoEffectsHelpText(
                dialHint = "撥輪：按住上下拖動可快速調節",
                longPressHint = "長按照片濾鏡撥輪：按分類選擇濾鏡",
            )
        } else {
            NativePhotoEffectsHelpText(
                dialHint = "拨轮：按住上下拖动可快速调节",
                longPressHint = "长按照片滤镜拨轮：按分类选择滤镜",
            )
        }
    }
}
