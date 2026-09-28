package com.ztransfer.lut

import java.io.IOException
import java.io.InputStream
import java.security.MessageDigest

internal enum class LutFailure { INVALID, UNSUPPORTED, TOO_LARGE, READ, GPU, INPUT_COLOR }
internal class LutException(val reason: LutFailure, detail: String) : IOException(detail)

/** Immutable by ownership: the packed array is never mutated after parsing. R varies fastest. */
internal class CubeLut(
    val size: Int,
    val domainMin: FloatArray,
    val domainMax: FloatArray,
    val rgb: FloatArray,
    val digest: String,
)

/** Bounded byte/line reader. Never allocates an unbounded line or a copy of the entire file. */
internal object CubeLutParser {
    const val MAX_BYTES = 32 * 1024 * 1024
    const val MAX_LINE = 8 * 1024
    const val MAX_SIZE = 65

    fun parse(source: InputStream, checkCancelled: () -> Unit = {}): CubeLut {
        val block = ByteArray(16 * 1024)
        val whitespace = Regex("\\s+")
        val hash = MessageDigest.getInstance("SHA-256")
        val line = ByteArray(MAX_LINE)
        var total = 0
        var count = 0
        var lineNumber = 0
        var size = 0
        var values: FloatArray? = null
        var offset = 0
        var dataStarted = false
        var titleSeen = false
        var minimum: FloatArray? = null
        var maximum: FloatArray? = null
        fun invalid(message: String): Nothing = throw LutException(LutFailure.INVALID, "Line $lineNumber: $message")
        fun triple(tokens: List<String>): FloatArray {
            if (tokens.size != 3) invalid("Expected three components")
            return FloatArray(3) { i ->
                tokens[i].toFloatOrNull()?.takeIf { it.isFinite() }
                    ?: invalid("Invalid number")
            }
        }
        fun consume() {
            checkCancelled()
            lineNumber++
            var text = String(line, 0, count, Charsets.UTF_8)
            if (lineNumber == 1) text = text.removePrefix("\uFEFF")
            text = text.substringBefore('#').trim()
            if (text.isEmpty()) return
            val tokens = text.split(whitespace)
            val command = tokens.first()
            when (command) {
                "TITLE" -> {
                    if (dataStarted || titleSeen) invalid("Misplaced or repeated TITLE")
                    titleSeen = true
                    if (tokens.size < 2) invalid("Missing title")
                }
                "LUT_3D_SIZE" -> {
                    if (dataStarted || size != 0 || tokens.size != 2) invalid("Invalid size declaration")
                    size = tokens[1].toIntOrNull() ?: invalid("Invalid grid size")
                    if (size !in 2..MAX_SIZE) throw LutException(LutFailure.UNSUPPORTED, "Grid size must be 2..$MAX_SIZE")
                    values = FloatArray(size * size * size * 3)
                }
                "DOMAIN_MIN", "DOMAIN_MAX" -> {
                    if (dataStarted) invalid("Domain after data")
                    val domain = triple(tokens.drop(1))
                    if (command == "DOMAIN_MIN") {
                        if (minimum != null) invalid("Repeated DOMAIN_MIN")
                        minimum = domain
                    } else {
                        if (maximum != null) invalid("Repeated DOMAIN_MAX")
                        maximum = domain
                    }
                }
                else -> {
                    if (command.first().isLetter()) throw LutException(LutFailure.UNSUPPORTED, "Unsupported directive: $command")
                    val target = values ?: invalid("Missing LUT_3D_SIZE")
                    dataStarted = true
                    if (offset + 3 > target.size) invalid("Extra table entries")
                    val color = triple(tokens)
                    for (value in color) {
                        if (value < -65504f || value > 65504f) invalid("Color exceeds half-float range")
                        target[offset++] = value
                    }
                }
            }
        }
        while (true) {
            checkCancelled()
            val read = source.read(block)
            if (read < 0) break
            if (read == 0) throw LutException(LutFailure.READ, "Stream made no progress")
            total += read
            if (total > MAX_BYTES) throw LutException(LutFailure.TOO_LARGE, "LUT exceeds $MAX_BYTES bytes")
            hash.update(block, 0, read)
            for (i in 0 until read) {
                val byte = block[i]
                if (byte == 10.toByte()) { consume(); count = 0 }
                else {
                    if (count == MAX_LINE) throw LutException(LutFailure.TOO_LARGE, "Line exceeds $MAX_LINE bytes")
                    line[count++] = byte
                }
            }
        }
        if (count != 0) consume()
        checkCancelled()
        val table = values ?: invalid("Missing table")
        if (offset != table.size) invalid("Incomplete table")
        val low = minimum ?: floatArrayOf(0f, 0f, 0f)
        val high = maximum ?: floatArrayOf(1f, 1f, 1f)
        for (i in 0..2) {
            val range = high[i] - low[i]
            if (!range.isFinite() || range < java.lang.Float.MIN_NORMAL ||
                !(1f / range).isFinite() || 1f / range < java.lang.Float.MIN_NORMAL ||
                (low[i] != 0f && kotlin.math.abs(low[i]) < java.lang.Float.MIN_NORMAL) ||
                (high[i] != 0f && kotlin.math.abs(high[i]) < java.lang.Float.MIN_NORMAL)) {
                invalid("Domain cannot be represented reliably by the GPU")
            }
        }
        return CubeLut(size, low, high, table, hash.digest().joinToString("") { "%02x".format(it.toInt() and 255) })
    }
}
