package com.ztransfer.ui.screen

import androidx.compose.ui.geometry.Rect
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class GenieLevelInletTest {
    @Test fun wideGpsPanelReturnsBothEdgesToTheButtonTogether() {
        // Include a narrow button and a right-side anchor to cover clamping and mirroring.
        for (button in listOf(Rect(12f, 50f, 167f, 100f),
            Rect(12f, 50f, 72f, 100f), Rect(107f, 50f, 262f, 100f))) {
            for (height in listOf(120f, 300f)) {
                val panel = Rect(12f, 106f, 262f, 106f + height)
                for (step in 100 downTo 0) {
                    val rows = (0..GENIE_BANDS).map { index ->
                        genieRow(step / 100f, index.toFloat() / GENIE_BANDS,
                            button, panel, mouthWidth = 80f, tiltEnabled = false)
                    }
                    rows.forEach { row ->
                        assertTrue(row.left.isFinite() && row.right.isFinite() && row.y.isFinite())
                        assertTrue(row.right > row.left)
                        assertEquals(row.leftY, row.rightY, .001f)
                        if (step == 0) {
                            assertEquals(button.center.x - panel.left, (row.left + row.right) / 2f, .001f)
                            assertEquals(minOf(80f, button.width), row.right - row.left, .001f)
                            assertEquals(button.bottom - panel.top, row.leftY, .001f)
                        } else if (step == 100) {
                            assertEquals(0f, row.left, .001f)
                            assertEquals(panel.width, row.right, .001f)
                        }
                    }
                    // Level horizontal strips with increasing Y cannot fold over each other.
                    if (step > 0) {
                        assertTrue(rows.zipWithNext().all { (top, bottom) -> bottom.y > top.y })
                    }
                    if (step == 100) {
                        assertEquals(0f, rows.first().y, .001f)
                        assertEquals(height, rows.last().y, .001f)
                    }
                }
            }
        }
    }

    @Test fun otherPopupsKeepTheirOriginalTiltByDefault() {
        val panel = Rect(12f, 106f, 262f, 406f)
        val button = Rect(12f, 50f, 167f, 100f)
        val row = genieRow(0f, 0f, button, panel, mouthWidth = 80f)
        assertTrue(row.leftY > row.rightY)
        assertEquals(button.bottom - panel.top, row.rightY, .001f)
    }
}
