package com.ztransfer.protocol

import org.junit.Assert.*
import org.junit.Test

class NikonPictureControlSelectionTest {
    // Actual user-supplied Z 30 V1.20 Wi-Fi response; current = Portrait, C9 empty.
    private val descriptor = "00D20400010800050002250001000200030004000500060007000800650066006700680069006A006B006C006D006E006F00700071007200730074007500760077007800C900CA00CB00CC00CD00CE00CF00D000D100"
        .chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    @Test fun cameraEnumeratesTheEmptyLastSlotSeparatelyFromTheActivePreset() {
        val selection = NikonPictureControlSelection.parse(descriptor)
        assertTrue(selection.writable)
        assertEquals(5, selection.current)
        assertEquals(37, selection.choices.size)
        assertEquals(209, selection.confirmedLastCustomSlot)
    }

    @Test fun partialCustomSlotListCannotRedirectTheReservedSlot() {
        val partial = descriptor.dropLast(2).toByteArray().apply { this[10] = 36 }
        assertNull(NikonPictureControlSelection.parse(partial).confirmedLastCustomSlot)
        val builtInOnly = descriptor.take(68).toByteArray().apply { this[10] = 28 }
        assertNull(NikonPictureControlSelection.parse(builtInOnly).confirmedLastCustomSlot)
    }

    @Test fun damagedAndDifferentPropertyDescriptorsCannotAuthorizeWrites() {
        for (length in 0 until descriptor.size) {
            assertThrows(IllegalArgumentException::class.java) {
                NikonPictureControlSelection.parse(descriptor.copyOf(length))
            }
        }
        assertThrows(IllegalArgumentException::class.java) {
            NikonPictureControlSelection.parse(descriptor.copyOf().apply { this[0] = 1 })
        }
        assertThrows(IllegalArgumentException::class.java) {
            NikonPictureControlSelection.parse(descriptor.copyOf().apply { this[2] = 2 })
        }
        assertFalse(NikonPictureControlSelection.parse(descriptor.copyOf().apply { this[4] = 0 }).writable)
    }
}
