"""Exact STA media parser extraction; Android IO/call sites remain byte-for-byte unchanged."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
BASELINE = "e5dbadb"
ANDROID = "app/src/main/java/com/ztransfer/protocol/NikonCamera.kt"
COMMON = "shared/src/commonMain/kotlin/com/ztransfer/protocol/StaDirectMediaPolicy.kt"
RANGES = [
    ("internal fun staDirectObjectExtension(", "/** Converts EXIF"),
    ("private fun jpegExifSegmentRange(", "/** Bounded JPEG marker audit"),
    ("internal data class JpegMpfPreviewReference(", "internal fun staDirectVideoCaptureDate("),
    ("internal data class StaDirectRawThumbnailProbePlan(", "/** Pure RAW parsing is shared"),
]

def baseline():
    return subprocess.check_output(["git", "show", BASELINE + ":" + ANDROID], cwd=ROOT).decode("utf8")

def extract(source):
    chunks = [source[source.index(a):source.index(b, source.index(a))] for a, b in RANGES]
    android = source
    for chunk in chunks:
        assert android.count(chunk) == 1
        android = android.replace(chunk, "", 1)
    common = "\n".join(chunks).replace("internal fun ", "fun ").replace("internal data class ", "data class ")
    common = common.replace("private fun jpegExifSegmentRange(", "fun jpegExifSegmentRange(")
    # Only ASCII brand equality is observed: invalid/high-bit bytes cannot equal "qt  ".
    common = common.replace('"ftyp".toByteArray()', '"ftyp".encodeToByteArray()')
    common = common.replace('header.copyOfRange(8, 12).toString(Charsets.US_ASCII)', 'header.copyOfRange(8, 12).decodeToString()')
    start = source.index("internal fun staDirectVideoCaptureDate(")
    end = source.index("\n}\n", start) + 3
    original_video = source[start:end]
    formatter = """            return runCatching {
                STA_DIRECT_DATE_FORMATTER.format(Instant.ofEpochSecond(unixSeconds))
            }.getOrNull()"""
    assert original_video.count(formatter) == 1
    shared_video = original_video.replace("internal fun staDirectVideoCaptureDate(bytes: ByteArray): String?",
        "fun staDirectVideoCaptureSeconds(bytes: ByteArray): Long?").replace(formatter, "            return unixSeconds")
    android = android.replace(original_video, """internal fun staDirectVideoCaptureDate(bytes: ByteArray): String? =
    staDirectVideoCaptureSeconds(bytes)?.let { unixSeconds ->
        runCatching { STA_DIRECT_DATE_FORMATTER.format(Instant.ofEpochSecond(unixSeconds)) }.getOrNull()
    }
""", 1)
    android = android.replace("private const val QUICKTIME_EPOCH_OFFSET_SECONDS = 2_082_844_800L\n", "", 1)
    common += "\nprivate const val QUICKTIME_EPOCH_OFFSET_SECONDS = 2_082_844_800L\n\n" + shared_video
    return android, "package com.ztransfer.protocol\n\nprivate const val STA_DIRECT_MAX_EMBEDDED_PREVIEW_BYTES = 16 * 1024 * 1024\n\n" + common.rstrip() + "\n"

def verify():
    for path, expected in zip((ANDROID, COMMON), extract(baseline())):
        assert (ROOT / path).read_text(encoding="utf8") == expected, path

def previous_sta_media_source(path, value):
    if path == ANDROID:
        original = baseline()
        assert value == extract(original)[0], "Android STA IO or callers changed outside extraction"
        return original
    return value
