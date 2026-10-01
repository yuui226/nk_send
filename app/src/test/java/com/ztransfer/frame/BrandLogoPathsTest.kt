package com.ztransfer.frame

import androidx.core.graphics.PathParser
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class BrandLogoPathsTest {
    @Test fun allBrandPathsHaveCompleteAndroidPathCommands() {
        val arities = mapOf('M' to 2, 'L' to 2, 'H' to 1, 'V' to 1,
            'C' to 6, 'S' to 4, 'Q' to 4, 'T' to 2, 'A' to 7)
        for ((brand, vector) in BrandLogoPaths.vectors) {
            val nodes = PathParser.createNodesFromPathData(vector.data)!!
            assertTrue(brand, nodes.isNotEmpty())
            for (node in nodes) {
                val command = node.type.uppercaseChar()
                val values = node.params
                if (command == 'Z') {
                    assertEquals(brand, 0, values.size)
                    continue
                }
                val arity = arities.getValue(command)
                assertTrue("$brand $command", values.isNotEmpty())
                assertEquals("$brand $command: incomplete parameters", 0, values.size % arity)
                assertTrue(brand, values.all { it.isFinite() })
                if (command == 'A') {
                    for (offset in values.indices step arity) {
                        assertTrue(brand, values[offset + 3] in listOf(0f, 1f))
                        assertTrue(brand, values[offset + 4] in listOf(0f, 1f))
                    }
                }
            }
        }
    }
}
