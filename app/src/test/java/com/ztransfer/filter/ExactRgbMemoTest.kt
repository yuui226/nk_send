package com.ztransfer.filter

import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test

class ExactRgbMemoTest {
    @Test fun collisionsNeverReturnAnotherColorsResultIncludingBlackAndWhite() {
        val memo = ExactRgbMemo(bits = 2)
        assertEquals(-1, memo.get(0))
        val colors = listOf(0, 0xffffff, 1, 0x123456, 0xabcdef, 0x007f80)
        repeat(100) {
            for (color in colors) memo.put(color, color xor 0xffffff)
            for (color in colors) {
                val result = memo.get(color)
                assertTrue(result == -1 || result == color xor 0xffffff)
            }
        }
        assertEquals(32, memo.bytes)
        assertEquals(8 * 1024 * 1024, ExactRgbMemo().bytes)
    }

    @Test fun concurrentEvictionCannotMixAnRgbKeyAndMappedValue() {
        val memo = ExactRgbMemo(bits = 4)
        val pool = Executors.newFixedThreadPool(4)
        try {
            val jobs = (0..3).map { worker -> pool.submit {
                repeat(50_000) { index ->
                    val rgb = (index * 31 + worker) and 0xffffff
                    val mapped = rgb xor 0x5a5a5a
                    memo.put(rgb, mapped)
                    val found = memo.get(rgb)
                    check(found == -1 || found == mapped)
                }
            } }
            jobs.forEach { it.get(5, TimeUnit.SECONDS) }
        } finally { pool.shutdownNow() }
    }
}
