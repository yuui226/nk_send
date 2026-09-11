package com.ztransfer.ui

import kotlin.test.Test
import kotlin.test.assertEquals

class NativePhotoEffectsTextTest {
    @Test
    fun keepsTheProductTerminologyAcrossThreeLocales() {
        assertEquals("拨轮：按住上下拖动可快速调节", NativePhotoEffectsText.forLanguage("zh-CN").dialHint)
        assertEquals("长按照片滤镜拨轮：按分类选择滤镜", NativePhotoEffectsText.forLanguage("zh-CN").longPressHint)
        assertEquals("撥輪：按住上下拖動可快速調節", NativePhotoEffectsText.forLanguage("zh-Hant").dialHint)
        assertEquals("Hold the photo filter dial: choose by category", NativePhotoEffectsText.forLanguage("en").longPressHint)
    }
}
