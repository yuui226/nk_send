package com.ztransfer.viewmodel

import java.util.RandomAccess

/**
 * 面向“小批追加、少量原位替换”的不可变列表。
 *
 * 已发布版本永不修改；下一批只复制块索引、受影响块和新的尾块，避免每收到一批照片
 * 都重新复制此前所有文件引用。
 */
internal class BatchPublishedList<T> private constructor(
    private val chunks: List<List<T>>,
    override val size: Int,
) : AbstractList<T>(), RandomAccess {

    override fun get(index: Int): T {
        if (index !in 0 until size) {
            throw IndexOutOfBoundsException("index=$index size=$size")
        }
        return chunks[index / CHUNK_SIZE][index % CHUNK_SIZE]
    }

    override fun iterator(): Iterator<T> = object : Iterator<T> {
        private var chunkIndex = 0
        private var itemIndex = 0

        override fun hasNext(): Boolean = chunkIndex < chunks.size

        override fun next(): T {
            if (!hasNext()) throw NoSuchElementException()
            val value = chunks[chunkIndex][itemIndex++]
            if (itemIndex == chunks[chunkIndex].size) {
                chunkIndex++
                itemIndex = 0
            }
            return value
        }
    }

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is List<*> || size != other.size) return false
        // StateFlow 发布追加批次时先比较新旧 CameraState。先判 size 可让常见追加路径
        // O(1) 返回；同尺寸替换也只比较块引用和受影响块，不重新遍历全部文件。
        return if (other is BatchPublishedList<*>) chunks == other.chunks else super.equals(other)
    }

    override fun hashCode(): Int = super.hashCode()

    /** 在一个新版本中合并本批替换和尾部新增，旧版本继续引用原块。 */
    fun withBatch(
        replacements: Map<Int, T>,
        additions: List<T>,
    ): BatchPublishedList<T> {
        if (replacements.isEmpty() && additions.isEmpty()) return this
        replacements.keys.forEach { index ->
            require(index in 0 until size) { "replacement index=$index size=$size" }
        }

        val nextChunks = chunks.toMutableList()
        replacements.entries.groupBy { it.key / CHUNK_SIZE }.forEach { (chunkIndex, entries) ->
            val updated = nextChunks[chunkIndex].toMutableList()
            entries.forEach { (index, value) -> updated[index % CHUNK_SIZE] = value }
            nextChunks[chunkIndex] = updated.toList()
        }

        if (additions.isNotEmpty()) {
            val source = additions.iterator()
            if (nextChunks.isNotEmpty() && nextChunks.last().size < CHUNK_SIZE) {
                val tail = ArrayList<T>(CHUNK_SIZE)
                tail.addAll(nextChunks.removeAt(nextChunks.lastIndex))
                while (source.hasNext() && tail.size < CHUNK_SIZE) tail += source.next()
                nextChunks += tail.toList()
            }
            while (source.hasNext()) {
                val chunk = ArrayList<T>(CHUNK_SIZE)
                while (source.hasNext() && chunk.size < CHUNK_SIZE) chunk += source.next()
                nextChunks += chunk.toList()
            }
        }

        return BatchPublishedList(nextChunks.toList(), size + additions.size)
    }

    companion object {
        private const val CHUNK_SIZE = 256

        @Suppress("UNCHECKED_CAST")
        fun <T> from(values: List<T>): BatchPublishedList<T> {
            if (values is BatchPublishedList<*>) return values as BatchPublishedList<T>
            if (values.isEmpty()) return BatchPublishedList(emptyList(), 0)
            return BatchPublishedList(
                chunks = values.chunked(CHUNK_SIZE).map { it.toList() },
                size = values.size,
            )
        }
    }
}
