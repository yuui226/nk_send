package com.ztransfer.viewmodel

import com.ztransfer.protocol.PtpConstants

/** Hidden name used for an original file until all camera bytes have been written. */
const val TRANSFER_PART_PREFIX = ".nkpart_"

/** A directory entry indexed without depending on a platform file or URI type. */
data class IndexedExistingFile<T>(
    val displayName: String,
    val size: Long,
    val value: T,
)

/** Parsed identity and original name from a resumable transfer part file. */
data class TransferPartName(
    val identityToken: String,
    val originalFileName: String,
)

/**
 * Unsynchronized existing-file index. Platform callers own synchronization so Android can retain
 * its current lock and iOS can put this value behind an actor or its own lock.
 */
class ExistingFileNameIndexCore<T> {
    private val byDisplayName = HashMap<String, IndexedExistingFile<T>>()
    private val byBaseName = HashMap<String, MutableList<IndexedExistingFile<T>>>()

    fun add(displayName: String, size: Long, value: T) {
        val entry = IndexedExistingFile(displayName, size, value)
        byDisplayName.put(displayName, entry)?.let { previous ->
            byBaseName[transferDirectoryLookupKey(previous.displayName)]?.removeAll {
                it.displayName == previous.displayName
            }
        }
        byBaseName.getOrPut(transferDirectoryLookupKey(displayName)) { ArrayList(1) }.add(entry)
    }

    /** Exact display-name checks intentionally remain case-sensitive. */
    fun containsDisplayName(displayName: String): Boolean = byDisplayName.containsKey(displayName)

    fun find(fileName: String, fileSize: Long): IndexedExistingFile<T>? =
        byDisplayName[fileName]?.takeIf { matchesExistingFileSize(it.size, fileSize) }
            ?: byBaseName[transferDirectoryLookupKey(fileName)]?.firstOrNull {
                matchesExistingFileSize(it.size, fileSize)
            }

    fun entries(): List<IndexedExistingFile<T>> = byDisplayName.values.toList()
}

/**
 * Removes every Android-compatible copy suffix: ` (n)` at the end of a name or immediately before
 * its final extension. ASCII digits and global replacement deliberately match the old JVM regex.
 */
fun exportedOriginalBaseName(name: String): String {
    var index = 0
    var result: StringBuilder? = null
    while (index < name.length) {
        val mayStartSuffix = name[index] == ' ' &&
            index + 3 < name.length &&
            name[index + 1] == '('
        if (mayStartSuffix) {
            var cursor = index + 2
            while (cursor < name.length && name[cursor] in '0'..'9') cursor++
            val hasDigits = cursor > index + 2
            val closesSuffix = cursor < name.length && name[cursor] == ')'
            val afterSuffix = cursor + 1
            val isEligiblePosition = isLegacyRegexEnd(name, afterSuffix) ||
                (
                    afterSuffix < name.length &&
                        name[afterSuffix] == '.' &&
                        name.indexOf('.', startIndex = afterSuffix + 1) < 0
                    )
            if (hasDigits && closesSuffix && isEligiblePosition) {
                if (result == null) result = StringBuilder(name.length).append(name, 0, index)
                index = afterSuffix
                continue
            }
        }
        result?.append(name[index])
        index++
    }
    return result?.toString() ?: name
}

/** Java regex `$` also matches immediately before one final line terminator. */
private fun isLegacyRegexEnd(value: String, index: Int): Boolean {
    if (index == value.length) return true
    if (index == value.length - 1) {
        return value[index] == '\n' ||
            value[index] == '\r' ||
            value[index] == '\u0085' ||
            value[index] == '\u2028' ||
            value[index] == '\u2029'
    }
    return index == value.length - 2 && value[index] == '\r' && value[index + 1] == '\n'
}

/** Locale-independent key used only for normalized original-file lookup. */
fun transferDirectoryLookupKey(name: String): String = exportedOriginalBaseName(name).lowercase()

/** Unknown local sizes and the PTP unknown-size sentinel retain their existing wildcard behavior. */
fun matchesExistingFileSize(localSize: Long, cameraFileSize: Long): Boolean =
    localSize < 0L || cameraFileSize == PtpConstants.SIZE_UNKNOWN || localSize == cameraFileSize

/** Keeps root and dated export buckets separate while matching their names case-insensitively. */
fun transferDestinationLookupKey(destinationFolderName: String?): String =
    destinationFolderName?.lowercase() ?: "\u0000root"

/** PTP capture date when valid, otherwise the day on which the task was queued. */
fun transferDateFolderName(captureDate: String?, fallbackDayKey: Int): String {
    val dayKey = transferCaptureDayKey(captureDate) ?: fallbackDayKey
    val year = dayKey / 10_000
    val month = dayKey / 100 % 100
    val day = dayKey % 100
    return "ZT${year.toString().padStart(4, '0')}-" +
        "${month.toString().padStart(2, '0')}-${day.toString().padStart(2, '0')}"
}

/** Mirrors strict ISO parsing used by Android, including ISO's valid proleptic year zero. */
private fun transferCaptureDayKey(captureDate: String?): Int? {
    if (captureDate == null || captureDate.length < 8) return null
    var dayKey = 0
    for (index in 0 until 8) {
        val digit = captureDate[index] - '0'
        if (digit !in 0..9) return null
        dayKey = dayKey * 10 + digit
    }
    val year = dayKey / 10_000
    val month = dayKey / 100 % 100
    val day = dayKey % 100
    if (month !in 1..12) return null
    val leapYear = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
    val lastDay = when (month) {
        2 -> if (leapYear) 29 else 28
        4, 6, 9, 11 -> 30
        else -> 31
    }
    return dayKey.takeIf { day in 1..lastDay }
}

fun transferDestinationFolderName(
    captureDate: String?,
    organizeTransfersByDate: Boolean,
    fallbackDayKey: Int,
): String? = if (organizeTransfersByDate) {
    transferDateFolderName(captureDate, fallbackDayKey)
} else {
    null
}

/** Shape-only check retained for enumerating date folders; calendar validity is not required. */
fun isDatedTransferFolderName(name: String): Boolean {
    if (name.length != 12 || !name.startsWith("ZT") || name[6] != '-' || name[9] != '-') {
        return false
    }
    return name.indices.all { index ->
        index == 6 || index == 9 || index < 2 || name[index] in '0'..'9'
    }
}

/** Identity used only to suppress duplicate automatic-transfer candidates in the current process. */
fun automaticTransferFileIdentity(
    fileName: String,
    size: Long,
    captureDate: String?,
): String = "$fileName|$size|$captureDate"

/** MIME value required by Android SAF; iOS may map the same extension to its native UTType. */
fun transferMimeType(fileName: String): String = when {
    fileName.endsWith(".jpg", ignoreCase = true) ||
        fileName.endsWith(".jpeg", ignoreCase = true) -> "image/jpeg"
    fileName.endsWith(".png", ignoreCase = true) -> "image/png"
    fileName.endsWith(".nef", ignoreCase = true) -> "image/x-nikon-nef"
    fileName.endsWith(".mov", ignoreCase = true) -> "video/quicktime"
    fileName.endsWith(".mp4", ignoreCase = true) -> "video/mp4"
    fileName.endsWith(".avi", ignoreCase = true) -> "video/x-msvideo"
    else -> "application/octet-stream"
}

/** Size and capture date with every character outside ASCII letters, digits, and `.` removed. */
fun transferPartIdentityToken(size: Long, captureDate: String?): String = buildString {
    "$size.${captureDate ?: "0"}".forEach { character ->
        if (
            character in 'A'..'Z' ||
            character in 'a'..'z' ||
            character in '0'..'9' ||
            character == '.'
        ) {
            append(character)
        }
    }
}

fun transferPartFileName(
    originalFileName: String,
    size: Long,
    captureDate: String?,
): String = TRANSFER_PART_PREFIX +
    transferPartIdentityToken(size, captureDate) +
    "_" +
    originalFileName

/** Splits on the first underscore after the prefix so underscores in the original name survive. */
fun parseTransferPartFileName(name: String): TransferPartName? {
    if (!name.startsWith(TRANSFER_PART_PREFIX)) return null
    val afterPrefix = name.removePrefix(TRANSFER_PART_PREFIX)
    val separator = afterPrefix.indexOf('_')
    if (separator <= 0 || separator == afterPrefix.lastIndex) return null
    return TransferPartName(
        identityToken = afterPrefix.substring(0, separator),
        originalFileName = afterPrefix.substring(separator + 1),
    )
}

/** `DSC_0001.NEF` plus 2 becomes `DSC_0001 (2).NEF`; leading dots are not extensions. */
fun suffixedTransferFileName(name: String, number: Int): String {
    val dot = name.lastIndexOf('.')
    return if (dot <= 0) {
        "$name ($number)"
    } else {
        "${name.substring(0, dot)} ($number)${name.substring(dot)}"
    }
}

/** Original-file fallback copies always require exact length, including zero and unknown values. */
fun isOriginalFileCopyComplete(copiedBytes: Long, expectedBytes: Long): Boolean =
    copiedBytes == expectedBytes
