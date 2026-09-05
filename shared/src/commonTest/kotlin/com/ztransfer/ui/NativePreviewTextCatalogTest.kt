package com.ztransfer.ui

import kotlin.test.*

class NativePreviewTextCatalogTest {
    @Test fun languageTagsFollowExistingNativeLanguageSelection() {
        val metadata: (com.ztransfer.protocol.CameraFileInfo, String) -> String = { _, _ -> error("No IO while selecting text") }
        for (tag in listOf("en", "en-US", "de", "", "ja")) assertEquals("Burst", NativePreviewTextCatalog.forLanguage(tag, metadata).burst)
        for (tag in listOf("zh", "zh-CN", "zh_Hans", "zh-Hans-HK")) assertEquals("连拍", NativePreviewTextCatalog.forLanguage(tag, metadata).burst)
        for (tag in listOf("zh-TW", "zh-Hant", "zh_hk", "zh-MO", "ZH-HANT-CN")) assertEquals("連拍", NativePreviewTextCatalog.forLanguage(tag, metadata).burst)
    }
}
