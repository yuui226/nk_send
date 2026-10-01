package com.ztransfer.ui.screen

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Matrix
import org.junit.Assert.assertEquals
import org.junit.Test

class GenieBandMatrixTest {
    @Test fun reusableMatrixMapsEveryTriangleWithoutRetainingPreviousTransforms() {
        val matrix=Matrix()
        val panel=Rect(12f,100f,292f,500f)
        val anchor=Rect(220f,50f,256f,86f)
        for(step in 0..100) for(index in 0 until 12) {
            val top=genieRow(step/100f,index/12f,anchor,panel)
            val bottom=genieRow(step/100f,(index+1)/12f,anchor,panel)
            val y0=panel.height*index/12
            val y1=panel.height*(index+1)/12
            for(upper in listOf(true,false)) {
                // Dirty other entries too, to verify the destination is fully reset.
                matrix[2,0]=7f
                matrix[3,3]=2f
                genieBandMatrix(panel.width,y0,y1,top,bottom,upper,matrix)
                val points=if(upper) listOf(
                    Offset(0f,y0) to Offset(top.left,top.leftY),
                    Offset(panel.width,y0) to Offset(top.right,top.rightY),
                    Offset(0f,y1) to Offset(bottom.left,bottom.leftY),
                ) else listOf(
                    Offset(panel.width,y0) to Offset(top.right,top.rightY),
                    Offset(panel.width,y1) to Offset(bottom.right,bottom.rightY),
                    Offset(0f,y1) to Offset(bottom.left,bottom.leftY),
                )
                points.forEach { (source,want) ->
                    val actual=matrix.map(source)
                    assertEquals(want.x,actual.x,.002f)
                    assertEquals(want.y,actual.y,.002f)
                }
            }
        }
    }
}
