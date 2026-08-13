package com.ztransfer.filter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PhotoFilterRendererTest {
    @Test
    fun neutralProtectionRejectsNoiseAndPreservesEstablishedColor() {
        assertEquals(0f, PhotoFilterRenderer.neutralProtectionWeight(0f), 0f)
        assertEquals(
            0f,
            PhotoFilterRenderer.neutralProtectionWeight(
                PhotoFilterRenderer.NEUTRAL_PROTECTION_CHROMA_START,
            ),
            0f,
        )
        assertEquals(
            1f,
            PhotoFilterRenderer.neutralProtectionWeight(
                PhotoFilterRenderer.NEUTRAL_PROTECTION_CHROMA_END,
            ),
            0f,
        )
        assertEquals(1f, PhotoFilterRenderer.neutralProtectionWeight(1f), 0f)
    }

    @Test
    fun neutralProtectionTransitionsSmoothlyAndMonotonically() {
        val start = PhotoFilterRenderer.NEUTRAL_PROTECTION_CHROMA_START
        val end = PhotoFilterRenderer.NEUTRAL_PROTECTION_CHROMA_END
        val middle = (start + end) / 2f
        assertEquals(0.5f, PhotoFilterRenderer.neutralProtectionWeight(middle), 0.0001f)

        val weights = (0..16).map { step ->
            PhotoFilterRenderer.neutralProtectionWeight(start + (end - start) * step / 16f)
        }
        assertTrue(weights.zipWithNext().all { (left, right) -> left <= right })
    }
}
