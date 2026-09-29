package com.ztransfer.filter

import org.junit.Assert.assertArrayEquals
import org.junit.Test

/** Verify the actual export loops without requiring Android bitmap allocation in this JVM test. */
class ExactRgbRendererParityTest {
    @Test fun boundedMemoMatchesDirectCalculationForEveryBuiltInPresetAndAlphaMode() {
        val renderer = PhotoFilterRenderer
        val methods = renderer.javaClass.declaredMethods
        val compile = methods.single { it.name == "compileFilter" }.apply { isAccessible = true }
        val direct = methods.single { it.name == "filterPixelRange" }.apply { isAccessible = true }
        val memoized = methods.single { it.name == "applyExactRgbMemoRange" }.apply { isAccessible = true }
        val random = java.util.Random(7)
        val input = IntArray(1024) { random.nextInt() } +
            intArrayOf(0, -1, 0x00123456, 0x7f123456, 0xff000000.toInt(), 0xff808080.toInt())
        val notCancelled = { false }
        for (preset in BuiltInPhotoFilters.all) for (strength in listOf(2, 80, 100)) {
            val selection = PhotoFilterSelection(preset, strength)
            val opaque = compile.invoke(renderer, selection, false)
            // A tiny memo forces frequent collisions and eviction, exercising recomputation.
            val memo = ExactRgbMemo(bits = 4)
            for (alpha in listOf(false, true)) {
                val expected = input.copyOf()
                val actual = input.copyOf()
                val compiled = compile.invoke(renderer, selection, alpha)
                direct.invoke(renderer, expected, 0, expected.size, compiled, notCancelled)
                memoized.invoke(renderer, actual, 0, actual.size, memo, opaque, alpha, notCancelled)
                assertArrayEquals("${preset.name} strength=$strength alpha=$alpha", expected, actual)
            }
        }
    }
}
