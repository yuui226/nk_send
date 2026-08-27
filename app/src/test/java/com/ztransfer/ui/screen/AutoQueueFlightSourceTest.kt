package com.ztransfer.ui.screen

import androidx.compose.ui.geometry.Rect
import com.ztransfer.protocol.NikonCamera
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AutoQueueFlightSourceTest {
    private val file = NikonCamera.FileInfo(42, 1L, "DSC_0042.JPG", "20260827T120000")
    private val photoBounds = Rect(10f, 20f, 110f, 120f)
    private val burstBounds = Rect(30f, 40f, 130f, 140f)

    @Test
    fun `visible photo uses its real cell`() {
        assertEquals(
            photoBounds,
            resolveAutoQueueFlightSource(
                files = listOf(file),
                visibleKeys = setOf(file.handle),
                cellBoundsByHandle = mapOf(file.handle to photoBounds),
                burstBoundsById = emptyMap(),
                burstIdByHandle = emptyMap(),
            ),
        )
    }

    @Test
    fun `visible collapsed burst uses collection cell`() {
        val burstId = "jpg_0040"
        assertEquals(
            burstBounds,
            resolveAutoQueueFlightSource(
                files = listOf(file),
                visibleKeys = setOf(burstCollectionGridKey(burstId)),
                cellBoundsByHandle = emptyMap(),
                burstBoundsById = mapOf(burstId to burstBounds),
                burstIdByHandle = mapOf(file.handle to burstId),
            ),
        )
    }

    @Test
    fun `composed but offscreen cells are not accepted as source`() {
        assertNull(
            resolveAutoQueueFlightSource(
                files = listOf(file),
                visibleKeys = emptySet(),
                cellBoundsByHandle = mapOf(file.handle to photoBounds),
                burstBoundsById = mapOf("burst" to burstBounds),
                burstIdByHandle = mapOf(file.handle to "burst"),
            ),
        )
    }
}
