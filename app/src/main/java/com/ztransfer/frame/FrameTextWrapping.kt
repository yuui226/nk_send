package com.ztransfer.frame

import android.graphics.Paint
import android.icu.text.BreakIterator
import java.util.Locale

/** Wrap descriptions without splitting surrogate pairs, combining marks or emoji sequences. */
internal fun wrapFrameDescription(text: String, paint: Paint, maxWidth: Float): List<String> {
    require(maxWidth.isFinite() && maxWidth > 0f)
    val trimmed = text.trim()
    if (trimmed.isEmpty()) return emptyList()
    // Most EXIF fields already fit. Avoid constructing ICU iterators for those rows.
    if ('\n' !in trimmed && '\r' !in trimmed && paint.measureText(trimmed) <= maxWidth) return listOf(trimmed)
    val result = mutableListOf<String>()
    val characters = BreakIterator.getCharacterInstance(Locale.ROOT)
    val words = BreakIterator.getLineInstance(Locale.ROOT)
    for (paragraph in text.lineSequence()) {
        val value = paragraph.trim()
        if (value.isEmpty()) continue
        characters.setText(value)
        words.setText(value)
        var start = 0
        while (start < value.length) {
            val measured = paint.breakText(value, start, value.length, true, maxWidth, null)
            val rawEnd = (start + measured).coerceAtMost(value.length)
            var end = if (characters.isBoundary(rawEnd)) rawEnd else characters.preceding(rawEnd)
            if (end <= start) end = characters.following(start)
            if (end < value.length) {
                val wordEnd = if (words.isBoundary(end)) end else words.preceding(end)
                // Prefer a word boundary unless it would leave most of the line empty.
                if (wordEnd > start && wordEnd - start >= (end - start) / 2) end = wordEnd
            }
            check(end > start && end <= value.length)
            value.substring(start, end).trim().takeIf(String::isNotEmpty)?.let(result::add)
            start = end
        }
    }
    return result
}
