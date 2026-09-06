package com.ztransfer.ui

import kotlin.test.*

class NativeDirectorySettingsModelTest {
    private class Platform : NativeDirectorySettingsPlatform {
        val calls = ArrayList<Long>()
        var callback: ((Long) -> Unit)? = null
        override fun selectDirectory(requestId: Long) { calls += requestId; callback?.invoke(requestId) }
    }

    @Test fun repeatedClicksShareOneRequestAndLateOrDuplicateCompletionsCannotFinishAnother() {
        val model = NativeDirectorySettingsModel(); val platform = Platform()
        assertTrue(model.attach(platform, "original", null))
        model.choose(); model.choose()
        assertEquals(listOf(1L), platform.calls); assertTrue(model.state.value.selecting)
        assertFalse(model.finish(0, "late")); assertEquals("original", model.state.value.description)
        assertTrue(model.finish(1, "rejected")); assertFalse(model.finish(1, "duplicate"))
        model.choose()
        assertEquals(listOf(1L, 2L), platform.calls)
        assertFalse(model.finish(1, "old")); assertTrue(model.state.value.selecting)
        assertTrue(model.finish(2, "current")); assertEquals("current", model.state.value.message)
    }

    @Test fun cancelDoesNotClearRestorationErrorOrChangeTheFrozenDescription() {
        val model = NativeDirectorySettingsModel(); val platform = Platform()
        model.attach(platform, "provider", "permission lost")
        model.choose(); assertTrue(model.finish(1, null))
        assertEquals(NativeDirectorySettingsState("provider", "permission lost", false), model.state.value)
        model.choose(); model.finish(2, "new failure")
        assertEquals(NativeDirectorySettingsState("provider", "new failure", false), model.state.value)
    }

    @Test fun closedPageCannotOpenPickerOrReceiveLateCompletionOrBeRebound() {
        val model = NativeDirectorySettingsModel(); val platform = Platform()
        model.attach(platform, "sandbox", null); model.choose(); model.close()
        assertFalse(model.finish(1, "late")); model.choose()
        assertEquals(listOf(1L), platform.calls)
        assertFalse(model.attach(Platform(), "different", null))
        assertEquals(NativeDirectorySettingsState(), model.state.value)
    }

    @Test fun synchronousPlatformFailureCompletionDoesNotLeaveTheButtonBusy() {
        val model = NativeDirectorySettingsModel(); val platform = Platform()
        platform.callback = { model.finish(it, "presenter unavailable") }
        model.attach(platform, "sandbox", null); model.choose()
        assertFalse(model.state.value.selecting); assertEquals("presenter unavailable", model.state.value.message)
        model.choose(); assertEquals(listOf(1L, 2L), platform.calls)
    }

    @Test fun missingOrSecondOwnerCannotDispatchOrReplaceTheOriginalBinding() {
        val model = NativeDirectorySettingsModel(); val first = Platform(); val second = Platform()
        model.choose(); assertFalse(model.state.value.selecting)
        assertTrue(model.attach(first, "first", null)); assertFalse(model.attach(second, "second", null))
        model.choose(); assertEquals(listOf(1L), first.calls); assertTrue(second.calls.isEmpty())
        assertEquals("first", model.state.value.description)
    }
}
