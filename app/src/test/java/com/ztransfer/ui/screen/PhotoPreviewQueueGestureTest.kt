package com.ztransfer.ui.screen

import androidx.compose.ui.geometry.Offset
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PhotoPreviewQueueGestureTest {
    @Test
    fun sharedQueueFlightCurveKeepsExactEndpointsAndArcsUpward() {
        val start = Offset(120f, 700f)
        val end = Offset(950f, 90f)
        fun point(progress: Float) = queueFlightBezierPoint(
            progress = progress,
            start = start,
            end = end,
            liftBasePx = 36f,
            maxLiftPx = 90f,
            minApexYPx = 12f,
            maxBowPx = 52f,
            bowFadeDistancePx = 160f,
        )

        assertEquals(start, point(0f))
        assertEquals(end, point(1f))
        assertTrue(point(0.5f).y < (start.y + end.y) / 2f)
    }
}
