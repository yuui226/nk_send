package com.ztransfer.protocol

private class RatingBytesNeeded(val offset: Long, val length: Int) : RuntimeException(null, null, false, false)
private class InvalidRatingContainer : RuntimeException(null, null, false, false)
private data class RatingRegion(val offset: Long, val bytes: ByteArray)

/** Nikon NCTG 0x1001, signed SHORT, verified by Z30 camera-side 2→3→5 changes. */
private fun locateVideoRating(fileSize: Long, read: (Long, Int) -> ByteArray): Int? {
    var boxes = 0
    fun uint(bytes: ByteArray, p: Int, n: Int): Long = (p until p+n).fold(0L) { v,i ->
        (v shl 8) or (bytes[i].toLong() and 255)
    }
    fun tags(start: Long, end: Long): Int? {
        var p = start
        repeat(2048) {
            if (end-p < 8) return null
            val h = read(p,8)
            val tag = uint(h,0,4)
            val type = uint(h,4,2).toInt()
            val count = uint(h,6,2)
            val unit = when (type) {
                1,2,6,7 -> 1
                3,8 -> 2
                4,9,11,13 -> 4
                5,10,12 -> 8
                else -> return null
            }
            val length = count*unit
            if (length > end-p-8) return null
            if (tag == 0x1001L) {
                if (type != 8 || count != 1L) return null
                val raw = uint(read(p+8,2),0,2).toInt().toShort().toInt()
                return raw.takeIf { it in -1..5 }
            }
            p += 8+length
        }
        return null
    }
    val path = arrayOf("moov", "udta", "NCDT", "NCTG")
    fun walk(start: Long, end: Long, depth: Int): Int? {
        var p = start
        while (end-p >= 8 && ++boxes <= 2048) {
            val h = read(p,8)
            val type = h.copyOfRange(4,8).toString(Charsets.ISO_8859_1)
            var size = uint(h,0,4)
            var header = 8L
            if (size == 1L) {
                if (end-p < 16) throw InvalidRatingContainer()
                size = uint(read(p+8,8),0,8); header = 16
            } else if (size == 0L) size = end-p
            if (size < header || size > end-p) throw InvalidRatingContainer()
            if (type == path[depth]) {
                val result = if (depth == path.lastIndex) tags(p+header,p+size)
                    else walk(p+header,p+size,depth+1)
                if (result != null) return result
            }
            p += size // Skip mdat and unrelated atoms without reading their contents.
        }
        return null
    }
    return walk(0,fileSize,0)
}

/** Prefix-only opportunistic parsing. Missing bytes are unknown, never a fabricated zero. */
internal fun parseNikonVideoRating(prefix: ByteArray, fileSize: Long = Long.MAX_VALUE): Int? = try {
    locateVideoRating(fileSize) { offset, count ->
        if (offset < 0 || offset > prefix.size.toLong()-count) throw RatingBytesNeeded(offset,count)
        prefix.copyOfRange(offset.toInt(),offset.toInt()+count)
    }
} catch (_: RatingBytesNeeded) { null } catch (_: InvalidRatingContainer) { null }

/** One 8KiB window normally suffices; at most 32 windows (256KiB), including tail moov layouts. */
internal suspend fun readNikonVideoRating(
    fileSize: Long,
    prefix: ByteArray? = null,
    read: suspend (Long, Int) -> ByteArray?,
): Int? {
    if (fileSize < 8 || fileSize == 0xffffffffL) return null
    val regions = ArrayList<RatingRegion>()
    prefix?.takeIf { it.isNotEmpty() }?.let { regions += RatingRegion(0,it) }
    repeat(33) { attempt ->
        try {
            return locateVideoRating(fileSize) { offset, count ->
                val region = regions.firstOrNull { offset >= it.offset && offset-it.offset <= it.bytes.size.toLong()-count }
                    ?: throw RatingBytesNeeded(offset,count)
                val p = (offset-region.offset).toInt()
                region.bytes.copyOfRange(p,p+count)
            }
        } catch (needed: RatingBytesNeeded) {
            if (attempt == 32 || needed.offset < 0 || needed.offset > fileSize-needed.length) return null
            val count = minOf(8192L,fileSize-needed.offset).toInt()
            val bytes = read(needed.offset,count) ?: return null
            if (bytes.size < needed.length || bytes.size > count) return null
            regions += RatingRegion(needed.offset,bytes)
        } catch (_: InvalidRatingContainer) { return null }
    }
    return null
}
