package com.ztransfer.preview

interface ThumbnailCropPixels {
    val width: Int
    val height: Int
    fun readLine(index: Int, horizontal: Boolean, into: IntArray)
}

data class ThumbnailCrop(val left: Int, val top: Int, val width: Int, val height: Int)

/** Original Android thumbnail-only detection. Never apply to an original or FHD image. */
object ThumbnailCropPolicy {
    const val BAR_BLACK_MAX = 32
    const val BAR_MAX_FRACTION = 0.15f
    const val BAR_AVG_MAX = 40

    fun letterbox(src: ThumbnailCropPixels): ThumbnailCrop? {
        val w = src.width
        val h = src.height
        if (w < 16 || h < 16) return null
        val buf = IntArray(maxOf(w, h))

        // 横线（y 行）或竖线（x 列）是否几乎全为近黑像素。隔点采样，量级仅几千次整数比较。
        fun lineIsBlack(index: Int, horizontal: Boolean): Boolean {
            val n = if (horizontal) w else h
            src.readLine(index, horizontal, buf)
            var dark = 0
            var total = 0
            var i = 0
            while (i < n) {
                val p = buf[i]
                if ((p ushr 16 and 0xFF) < BAR_BLACK_MAX &&
                    (p ushr 8 and 0xFF) < BAR_BLACK_MAX &&
                    (p and 0xFF) < BAR_BLACK_MAX
                ) dark++
                total++
                i += 2
            }
            return dark * 100 >= total * 97
        }

        // 从两端向内数黑线；不成对/不对称/越过上限均按"无黑边"处理，成对时各 +1px 裁掉过渡线。
        fun scanPair(size: Int, isBlack: (Int) -> Boolean): Pair<Int, Int> {
            val limit = (size * BAR_MAX_FRACTION).toInt()
            var a = 0
            while (a < limit && isBlack(a)) a++
            var b = 0
            while (b < limit && isBlack(size - 1 - b)) b++
            return if (a == 0 || b == 0 || a >= limit || b >= limit || kotlin.math.abs(a - b) > 3) 0 to 0
            else a + 1 to b + 1
        }

        val (top, bottom) = scanPair(h) { y -> lineIsBlack(y, horizontal = true) }
        val (left, right) = scanPair(w) { x -> lineIsBlack(x, horizontal = false) }
        if (top == 0 && left == 0) return null
        return ThumbnailCrop(left, top, w - left - right, h - top - bottom)
    }

    fun videoBars(src: ThumbnailCropPixels): ThumbnailCrop? {
        val w = src.width
        val h = src.height
        if (w < 16 || h < 16) return null
        val cut = (h - w * 9 / 16) / 2
        if (cut < 2 || h - (cut + 1) * 2 < 8) return null   // 已接近 16:9 或图太小，无带可裁
        val buf = IntArray(w)
        fun bandIsDark(y0: Int, y1: Int): Boolean {
            var sum = 0L
            var cnt = 0
            var y = y0
            while (y < y1) {
                src.readLine(y, true, buf)
                var x = 0
                while (x < w) {
                    val p = buf[x]
                    sum += maxOf(p ushr 16 and 0xFF, p ushr 8 and 0xFF, p and 0xFF)
                    cnt++
                    x += 2
                }
                y += 2
            }
            return cnt > 0 && sum < cnt.toLong() * BAR_AVG_MAX
        }
        if (!bandIsDark(0, cut) || !bandIsDark(h - cut, h)) return null
        return ThumbnailCrop(0, cut + 1, w, h - (cut + 1) * 2)
    }
}
