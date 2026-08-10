package com.ztransfer.ui.screen

import kotlin.math.abs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class LiquidProgressWaveTest {

    @Test
    fun envelopeFlattensAtBothEnds() {
        assertEquals(0f, liquidProgressWaveEnvelope(0f), 0f)
        assertEquals(0f, liquidProgressWaveEnvelope(0.05f), 0f)
        assertEquals(1f, liquidProgressWaveEnvelope(0.5f), 0f)
        assertEquals(0f, liquidProgressWaveEnvelope(0.98f), 0f)
        assertEquals(0f, liquidProgressWaveEnvelope(1f), 0f)
        assertEquals(0f, liquidProgressWaveEnvelope(Float.NaN), 0f)
        assertEquals(0f, liquidProgressWaveEnvelope(Float.POSITIVE_INFINITY), 0f)
        assertEquals(0f, liquidProgressWaveEnvelope(Float.NEGATIVE_INFINITY), 0f)
        for (step in -10..110) {
            assertTrue(liquidProgressWaveEnvelope(step / 100f) in 0f..1f)
        }
    }

    @Test
    fun taskSeedIsStableButVariesAcrossTasks() {
        assertEquals(liquidProgressWaveSeed(42L), liquidProgressWaveSeed(42L), 0f)
        assertNotEquals(liquidProgressWaveSeed(42L), liquidProgressWaveSeed(43L))
    }

    @Test
    fun waveIsBoundedAndSeamlessAcrossCycleAndSpatialScales() {
        listOf(0.55f, 1f).forEach { spatialScale ->
            listOf(0f, 0.19f, 0.63f, 1f).forEach { seed ->
                for (step in 0..40) {
                    val y = step / 40f
                    val start = liquidProgressWaveUnitOffset(
                        normalizedY = y,
                        phaseTurns = 0f,
                        seedTurns = seed,
                        spatialScale = spatialScale,
                    )
                    val end = liquidProgressWaveUnitOffset(
                        normalizedY = y,
                        phaseTurns = 1f,
                        seedTurns = seed,
                        spatialScale = spatialScale,
                    )
                    assertEquals(start, end, 0.0001f)
                    for (phaseStep in 0..20) {
                        val offset = liquidProgressWaveUnitOffset(
                            normalizedY = y,
                            phaseTurns = phaseStep / 20f,
                            seedTurns = seed,
                            spatialScale = spatialScale,
                        )
                        assertTrue(abs(offset) <= 1.0001f)
                    }
                }
            }
        }
    }
}
