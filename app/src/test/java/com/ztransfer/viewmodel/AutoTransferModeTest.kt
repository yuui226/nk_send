package com.ztransfer.viewmodel

import org.junit.Assert.*
import org.junit.Test

class AutoTransferModeTest {
    @Test fun supportedFormatsArePartitionedWithoutRawVideoConfusion() {
        val files = listOf("a.JPG", "a.jpeg", "a.NEF", "a.MOV", "a.mp4", "a.NEV", "a.HIF", "a.NRW", "a.wav", "no-extension")
        assertEquals(files.take(5), files.filter(AutoTransferMode.ALL::accepts))
        assertEquals(files.take(2), files.filter(AutoTransferMode.JPG::accepts))
        assertEquals(listOf("a.NEF"), files.filter(AutoTransferMode.RAW::accepts))
        assertEquals(listOf("a.MOV", "a.mp4"), files.filter(AutoTransferMode.VIDEO::accepts))
        assertTrue(files.none(AutoTransferMode.OFF::accepts))
    }
    @Test fun restoresNewModesAndMigratesOldSwitch() {
        assertEquals(AutoTransferMode.ALL, AutoTransferMode.restored(null, true))
        assertEquals(AutoTransferMode.OFF, AutoTransferMode.restored(null, false))
        AutoTransferMode.entries.forEach { assertEquals(it, AutoTransferMode.restored(it.name, true)) }
    }
}
