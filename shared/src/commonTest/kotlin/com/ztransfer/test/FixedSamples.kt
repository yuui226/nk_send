package com.ztransfer.test

/** Decodes an inline, filesystem-independent hexadecimal fixture on every KMP test target. */
internal fun hexBytes(value: String): ByteArray {
    require(value.length % 2 == 0) { "Hex sample must contain complete bytes" }
    return ByteArray(value.length / 2) { index ->
        value.substring(index * 2, index * 2 + 2).toInt(16).toByte()
    }
}

/** Keeps byte fixtures readable as unsigned integer literals while preserving their low 8 bits. */
internal fun byteValues(vararg values: Int): ByteArray =
    ByteArray(values.size) { index -> values[index].toByte() }
