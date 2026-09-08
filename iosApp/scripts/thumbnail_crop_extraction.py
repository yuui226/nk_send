"""Exact Android thumbnail crop math extraction; only bitmap/pixel access remains in Android."""
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BASELINE = "e5dbadb"
ANDROID = "app/src/main/java/com/ztransfer/viewmodel/CameraViewModel.kt"
COMMON = "shared/src/commonMain/kotlin/com/ztransfer/preview/ThumbnailCropPolicy.kt"

def baseline():
    return subprocess.check_output(["git", "show", BASELINE + ":" + ANDROID], cwd=ROOT).decode("utf8")

def extract(source):
    android = source
    functions = []
    adapter = """    private fun thumbnailCropPixels(src: Bitmap) = object : com.ztransfer.preview.ThumbnailCropPixels {
        override val width: Int get() = src.width
        override val height: Int get() = src.height
        override fun readLine(index: Int, horizontal: Boolean, into: IntArray) {
            if (horizontal) src.getPixels(into, 0, src.width, 0, index, src.width, 1)
            else src.getPixels(into, 0, 1, index, 0, 1, src.height)
        }
    }

"""
    for name, shared in (("cropLetterbox", "letterbox"), ("cropVideoBars", "videoBars")):
        start = source.index("    private fun " + name + "(")
        end = source.index("\n    }\n", start) + 7
        original = source[start:end]
        body = original.replace("private fun " + name + "(src: Bitmap): Bitmap", "fun " + shared + "(src: ThumbnailCropPixels): ThumbnailCrop?")
        body = body.replace("return src", "return null")
        body = body.replace("return Bitmap.createBitmap(src, ", "return ThumbnailCrop(")
        body = body.replace("if (horizontal) src.getPixels(buf, 0, w, 0, index, w, 1)\n            else src.getPixels(buf, 0, 1, index, 0, 1, h)", "src.readLine(index, horizontal, buf)")
        body = body.replace("src.getPixels(buf, 0, w, 0, y, w, 1)", "src.readLine(y, true, buf)")
        functions.append(body)
        wrapper = ("    private fun " + name + "(src: Bitmap): Bitmap {\n"
                   "        val crop = com.ztransfer.preview.ThumbnailCropPolicy." + shared + "(thumbnailCropPixels(src)) ?: return src\n"
                   "        return Bitmap.createBitmap(src, crop.left, crop.top, crop.width, crop.height)\n"
                   "    }\n")
        android = android.replace(original, (adapter if shared == "letterbox" else "") + wrapper, 1)
    constants = []
    for name in ("BAR_BLACK_MAX", "BAR_MAX_FRACTION", "BAR_AVG_MAX"):
        line = next(x for x in source.splitlines() if "const val " + name + " =" in x)
        constants.append("    " + line.strip())
        android = android.replace(line, line.split("=")[0] + "= com.ztransfer.preview.ThumbnailCropPolicy." + name, 1)
    common = ("package com.ztransfer.preview\n\n"
              "interface ThumbnailCropPixels {\n    val width: Int\n    val height: Int\n"
              "    fun readLine(index: Int, horizontal: Boolean, into: IntArray)\n}\n\n"
              "data class ThumbnailCrop(val left: Int, val top: Int, val width: Int, val height: Int)\n\n"
              "/** Original Android thumbnail-only detection. Never apply to an original or FHD image. */\n"
              "object ThumbnailCropPolicy {\n" + "\n".join(constants) + "\n\n" + "\n".join(functions) + "}\n")
    return android, common

def verify():
    for path, expected in zip((ANDROID, COMMON), extract(baseline())):
        assert (ROOT / path).read_text(encoding="utf8") == expected, path

def previous_thumbnail_crop_source(path, value):
    if path == ANDROID:
        original = baseline()
        assert value == extract(original)[0], "Android crop IO/callers changed outside the exact adapter"
        return original
    return value
