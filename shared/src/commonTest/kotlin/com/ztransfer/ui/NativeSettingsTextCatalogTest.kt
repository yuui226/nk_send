package com.ztransfer.ui

import com.ztransfer.ui.screen.SettingsTextKey
import com.ztransfer.ui.theme.SkinPreset
import kotlin.test.*

class NativeSettingsTextCatalogTest {
    @Test fun interactionOptionsHaveActualLineBreaksLikeCompiledAndroidResources() {
        for ((tag, preview, transfer) in listOf(
            Triple("en", "Tap: preview\nHold: transfer", "Tap: transfer\nHold: preview"),
            Triple("zh-Hans", "点击：预览\n长按：传输", "点击：传输\n长按：预览"),
            Triple("zh-Hant", "點擊：預覽\n長按：傳輸", "點擊：傳輸\n長按：預覽"),
        )) {
            val text = NativeSettingsTextCatalog.forLanguage(tag)
            assertEquals(preview, text.value(SettingsTextKey.tap_preview_hold_transfer))
            assertEquals(transfer, text.value(SettingsTextKey.tap_transfer_hold_preview))
        }
    }

    @Test fun originalLanguageVariantsHaveEverySettingAndSkinLabel() {
        val en = NativeSettingsTextCatalog.forLanguage("en-US")
        val hans = NativeSettingsTextCatalog.forLanguage("zh-Hans")
        val hant = NativeSettingsTextCatalog.forLanguage("zh-Hant")
        for (text in listOf(en, hans, hant)) {
            assertTrue(text.title.isNotBlank()); assertTrue(text.close.isNotBlank())
            SettingsTextKey.entries.forEach { assertTrue(text.value(it).isNotBlank(), it.name) }
            SkinPreset.entries.forEach { assertTrue(text.skinValue(it).isNotBlank(), it.name) }
        }
        assertSame(en, NativeSettingsTextCatalog.forLanguage("fr-FR"))
        assertSame(hant, NativeSettingsTextCatalog.forLanguage("zh_TW"))
        assertSame(hant, NativeSettingsTextCatalog.forLanguage("zh-HK"))
        assertSame(hans, NativeSettingsTextCatalog.forLanguage("zh-Hans-TW"))
        assertSame(hant, NativeSettingsTextCatalog.forLanguage("zh-Hant-CN"))
        assertSame(hans, NativeSettingsTextCatalog.forLanguage("zh"))
    }
}
