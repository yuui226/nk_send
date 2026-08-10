package com.ztransfer.ui.screen

import kotlin.math.abs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class QueuePillWaveTest {

    @Test
    fun envelopeFlattensAtBothEnds() {
        assertEquals(0f, queuePillWaveEnvelope(0f), 0f)
        assertEquals(0f, queuePillWaveEnvelope(0.05f), 0f)
        assertEquals(1f, queuePillWaveEnvelope(0.5f), 0f)
        assertEquals(0f, queuePillWaveEnvelope(0.98f), 0f)
        assertEquals(0f, queuePillWaveEnvelope(1f), 0f)
        for (step in -10..110) {
            assertTrue(queuePillWaveEnvelope(step / 100f) in 0f..1f)
        }
    }

    @Test
    fun taskSeedIsStableButVariesAcrossTasks() {
        assertEquals(queuePillWaveSeed(42L), queuePillWaveSeed(42L), 0f)
        assertNotEquals(queuePillWaveSeed(42L), queuePillWaveSeed(43L))
    }

    @Test
    fun waveIsBoundedAndSeamlessAcrossCycle() {
        listOf(0f, 0.19f, 0.63f, 1f).forEach { seed ->
            for (step in 0..40) {
                val y = step / 40f
                val start = queuePillWaveUnitOffset(y, phaseTurns = 0f, seedTurns = seed)
                val end = queuePillWaveUnitOffset(y, phaseTurns = 1f, seedTurns = seed)
                assertEquals(start, end, 0.0001f)
                for (phaseStep in 0..20) {
                    val offset = queuePillWaveUnitOffset(
                        normalizedY = y,
                        phaseTurns = phaseStep / 20f,
                        seedTurns = seed,
                    )
                    assertTrue(abs(offset) <= 1.0001f)
                }
            }
        }
    }
}
