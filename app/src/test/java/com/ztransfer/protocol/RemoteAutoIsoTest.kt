package com.ztransfer.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteAutoIsoTest {
    @Test
    fun movieModePrefersZ30AutoIsoProperty() {
        assertEquals(
            listOf(
                Lab.PROP_NK_AUTO_ISO_ALT,
                Lab.PROP_NK_AUTO_ISO
            ),
            rcAutoIsoCandidateProps(movieMode = true)
        )
    }

    @Test
    fun photoModeKeepsLegacyPropertyOrder() {
        assertEquals(
            listOf(Lab.PROP_NK_AUTO_ISO, Lab.PROP_NK_AUTO_ISO_ALT),
            rcAutoIsoCandidateProps(movieMode = false)
        )
    }

    @Test
    fun onlyWritableTwoStatePropertiesBecomeSwitches() {
        fun param(writable: Boolean, values: List<Long>) = RcParam(
            prop = Lab.PROP_NK_AUTO_ISO_ALT,
            dataType = 0x0002,
            writable = writable,
            current = values.firstOrNull() ?: 0L,
            values = values
        )

        assertTrue(param(writable = true, values = listOf(0L, 1L)).rcIsBinaryToggle())
        assertFalse(param(writable = false, values = listOf(0L, 1L)).rcIsBinaryToggle())
        assertFalse(param(writable = true, values = listOf(1L)).rcIsBinaryToggle())
    }
}
