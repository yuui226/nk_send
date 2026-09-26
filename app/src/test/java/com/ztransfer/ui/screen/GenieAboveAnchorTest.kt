package com.ztransfer.ui.screen

import androidx.compose.ui.geometry.Rect
import org.junit.Assert.*
import org.junit.Test

class GenieAboveAnchorTest {
    @Test fun aboveMenuSettlesUprightAndReturnsToButtonTop() {
        val panel=Rect(20f,30f,220f,330f)
        val anchor=Rect(40f,340f,76f,376f)
        for(i in 0..48) {
            val f=i/48f
            val row=genieRowAbove(1f,f,anchor,panel,28f)
            assertEquals(0f,row.left,.001f)
            assertEquals(panel.width,row.right,.001f)
            assertEquals(panel.height*f,row.y,.001f)
            assertEquals(0f,row.tilt,.001f)
        }
        val dock=genieRowAbove(0f,1f,anchor,panel,28f)
        assertEquals(anchor.center.x-panel.left,(dock.left+dock.right)/2f,.001f)
        assertEquals(anchor.top-panel.top,maxOf(dock.leftY,dock.rightY),.001f)
        for(step in 0..100) {
            val rows=(0..48).map { genieRowAbove(step/100f,it/48f,anchor,panel,28f) }
            assertTrue(rows.all { it.left.isFinite() && it.right>it.left && it.y.isFinite() })
            assertTrue(rows.zipWithNext().all { (a,b) -> a.y<=b.y+.001f })
        }
    }
}
