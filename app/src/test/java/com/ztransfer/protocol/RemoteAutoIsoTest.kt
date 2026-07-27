package com.ztransfer.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteAutoIsoTest {
    @Test
    fun movieModePrefersDedicatedMovieAutoIsoProperty() {
        assertEquals(
            listOf(
                Lab.PROP_NK_MOVIE_AUTO_ISO,
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
        fun param(
            writable: Boolean,
            values: List<Long>,
            dataType: Int = 0x0002,
            current: Long = values.firstOrNull() ?: 0L
        ) = RcParam(
            prop = Lab.PROP_NK_AUTO_ISO_ALT,
            dataType = dataType,
            writable = writable,
            current = current,
            values = values
        )

        assertTrue(param(writable = true, values = listOf(0L, 1L)).rcIsBinaryToggle())
        assertTrue(param(writable = true, values = emptyList(), current = 0L).rcIsBinaryToggle())
        assertTrue(param(writable = true, values = emptyList(), current = 1L).rcIsBinaryToggle())
        assertFalse(param(writable = false, values = listOf(0L, 1L)).rcIsBinaryToggle())
        assertFalse(param(writable = true, values = listOf(1L)).rcIsBinaryToggle())
        assertFalse(
            param(
                writable = true,
                values = emptyList(),
                dataType = 0x0004,
                current = 1L
            ).rcIsBinaryToggle()
        )
        assertFalse(param(writable = true, values = emptyList(), current = 2L).rcIsBinaryToggle())
    }
}
