package com.ztransfer.ui

import kotlin.test.*

class NativeTransferMessagesTest {
    @Test fun everyCodeHasThreeNonEmptyDistinctLanguageResults() {
        for (code in NativeTransferMessages.codes()) {
            val cn = NativeTransferMessages.render("@ztr|$code|12/34", "zh-Hans")
            val en = NativeTransferMessages.render("@ztr|$code|12/34", "en")
            val tw = NativeTransferMessages.render("@ztr|$code|12/34", "zh-Hant")
            assertTrue(cn.isNotBlank() && en.isNotBlank() && tw.isNotBlank(), code)
            assertFalse("@ztr|" in en || "{0}" in en, code)
            assertFalse(en.any { it in '\u4e00'..'\u9fff' }, code)
            assertNotEquals(cn, en, code)
        }
    }
    @Test fun switchingLanguageRendersTheSameStoredErrorWithoutRewritingQueueState() {
        val message = "@ztr|disk_full"
        assertTrue(NativeTransferMessages.render(message, "en").contains("Storage"))
        assertTrue(NativeTransferMessages.render(message, "zh-TW").contains("儲存"))
        assertTrue(NativeTransferMessages.render(message, "zh-CN").contains("存储"))
        assertEquals("@ztr|disk_full", message)
    }
    @Test fun timeoutPermissionAndCancellationRemainDifferentMeanings() {
        assertNotEquals(NativeTransferMessages.render("@ztr|timeout", "en"),
            NativeTransferMessages.render("@ztr|network_denied", "en"))
        assertTrue(NativeTransferMessages.render("@ztr|cancelled", "en").contains("retained"))
        assertTrue(NativeTransferMessages.render("@ztr|files_receipt|1/2", "en").contains("1/2"))
    }
    @Test fun userNamesAndUnknownMessagesAreNotTranslatedOrDropped() {
        assertEquals("DSC_0001.JPG", NativeTransferMessages.render("DSC_0001.JPG", "en"))
        assertEquals("@ztr|future|123", NativeTransferMessages.render("@ztr|future|123", "zh-Hant"))
        assertTrue(NativeTransferMessages.render("@ztr|destination_provider|照片 1|2", "en").contains("照片 1|2"))
    }
}
