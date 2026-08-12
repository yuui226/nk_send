package com.ztransfer.viewmodel

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertSame
import org.junit.Test

class BatchPublishedListTest {
    @Test
    fun `every published batch matches the mutable reference`() {
        val reference = ArrayList<Int>()
        var published = BatchPublishedList.from<Int>(emptyList())

        (0 until 2_000).chunked(20).forEach { batch ->
            reference += batch
            published = published.withBatch(emptyMap(), batch)
            assertEquals(reference, published)
        }
    }

    @Test
    fun `old snapshots remain unchanged after append and replacement`() {
        val first = BatchPublishedList.from((0 until 300).toList())
        val frozenFirst = first.toList()

        val second = first.withBatch(
            replacements = mapOf(0 to -1, 255 to -2, 256 to -3, 299 to -4),
            additions = (300 until 340).toList(),
        )

        assertEquals(frozenFirst, first)
        assertEquals(340, second.size)
        assertEquals(-1, second[0])
        assertEquals(-2, second[255])
        assertEquals(-3, second[256])
        assertEquals(-4, second[299])
        assertEquals((300 until 340).toList(), second.subList(300, 340))
    }

    @Test
    fun `empty batch reuses the current snapshot`() {
        val list = BatchPublishedList.from(listOf(1, 2, 3))

        assertSame(list, list.withBatch(emptyMap(), emptyList()))
        assertSame(list, BatchPublishedList.from(list))
    }

    @Test
    fun `list equality remains content based`() {
        val first = BatchPublishedList.from((0 until 600).toList())
        val equalCopy = BatchPublishedList.from((0 until 600).toList())
        val changed = first.withBatch(mapOf(300 to -1), emptyList())

        assertEquals(equalCopy, first)
        assertEquals(first.hashCode(), equalCopy.hashCode())
        assertNotEquals(first, changed)
    }
}
