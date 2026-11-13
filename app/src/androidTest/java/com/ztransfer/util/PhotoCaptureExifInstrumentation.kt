package com.ztransfer.util

import android.app.Activity
import android.app.Instrumentation
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.os.Bundle
import android.os.ParcelFileDescriptor
import androidx.exifinterface.media.ExifInterface
import com.ztransfer.frame.PhotoEffectIdentityJpeg
import java.io.File
import kotlin.math.abs
import kotlin.math.log2
import kotlin.math.roundToLong

/** Real JPEG read/copy/save/reopen coverage for both crop files and effect-export descriptors. */
class PhotoCaptureExifInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        start()
    }

    override fun onStart() {
        val result = Bundle()
        var code = Activity.RESULT_CANCELED
        val directory = File(targetContext.cacheDir, "capture-exif-test").apply { mkdirs() }
        try {
            val exposures = listOf(
                1L to 60L, 1L to 125L, 1L to 1145L, 1L to 1600L, 1L to 8000L, 1L to 16000L,
                137L to 1000000L, 1234567L to 100000000L, 1L to 3L, 3L to 2L, 30L to 1L,
            )
            for ((numerator, denominator) in exposures) {
                for (useDescriptor in listOf(false, true)) {
                    verifyCopy(directory, numerator, denominator, useDescriptor)
                }
            }
            result.putString(
                "result",
                "PASS: ${exposures.size * 2} JPEG round trips; exposure precision, capture fields, output geometry, " +
                    "source bytes and effect identity preserved",
            )
            code = Activity.RESULT_OK
        } catch (failure: Throwable) {
            result.putString("failure", failure.stackTraceToString())
        } finally {
            directory.deleteRecursively()
        }
        finish(code, result)
    }

    private fun verifyCopy(directory: File, numerator: Long, denominator: Long, useDescriptor: Boolean) {
        val source = File(directory, "source.jpg")
        val output = File(directory, "output.jpg")
        val exposure = numerator.toDouble() / denominator
        val label = "$numerator/$denominator descriptor=$useDescriptor"
        val identity = "a".repeat(64)
        writeJpeg(source, 96, 64)
        val sourceFields = mapOf(
            ExifInterface.TAG_MAKE to "NIKON",
            ExifInterface.TAG_MODEL to "Capture EXIF fixture",
            ExifInterface.TAG_EXPOSURE_TIME to "$numerator/$denominator",
            ExifInterface.TAG_SHUTTER_SPEED_VALUE to "${(-log2(exposure) * 1000000).roundToLong()}/1000000",
            ExifInterface.TAG_F_NUMBER to "28/10",
            ExifInterface.TAG_APERTURE_VALUE to "2970854/1000000",
            ExifInterface.TAG_PHOTOGRAPHIC_SENSITIVITY to "640",
            ExifInterface.TAG_FOCAL_LENGTH to "22/10",
            ExifInterface.TAG_FOCAL_LENGTH_IN_35MM_FILM to "15",
            ExifInterface.TAG_DATETIME_ORIGINAL to "2026:10:23 12:34:56",
            ExifInterface.TAG_SUBSEC_TIME_ORIGINAL to "789",
            ExifInterface.TAG_OFFSET_TIME_ORIGINAL to "+08:00",
        )
        ExifInterface(source).apply {
            sourceFields.forEach { (tag, value) -> setAttribute(tag, value) }
            setAttribute(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_ROTATE_90.toString())
            setAttribute(ExifInterface.TAG_PIXEL_X_DIMENSION, "96")
            setAttribute(ExifInterface.TAG_PIXEL_Y_DIMENSION, "64")
            setLatLong(31.234567, 121.456789)
            saveAttributes()
        }
        val originalBytes = source.readBytes()
        val original = ExifInterface(source)
        assertNear(exposure, original.getAttributeDouble(ExifInterface.TAG_EXPOSURE_TIME, Double.NaN), label)
        val attributes = if (useDescriptor) {
            ParcelFileDescriptor.open(source, ParcelFileDescriptor.MODE_READ_ONLY).use {
                readPhotoCaptureExif(ExifInterface(it.fileDescriptor))
            }
        } else {
            readPhotoCaptureExif(original)
        }
        val copiedKeys = attributes.map { it.first }.toSet()
        check(sourceFields.keys.all { it in copiedKeys }) { "Capture field omitted: $label" }
        check(listOf(
            ExifInterface.TAG_ORIENTATION,
            ExifInterface.TAG_IMAGE_WIDTH,
            ExifInterface.TAG_IMAGE_LENGTH,
            ExifInterface.TAG_PIXEL_X_DIMENSION,
            ExifInterface.TAG_PIXEL_Y_DIMENSION,
        ).none { it in copiedKeys }) { "Original geometry must not be copied: $label" }

        writeJpeg(output, 48, 72, identity)
        fun save(target: ExifInterface) {
            attributes.forEach { (tag, value) -> target.setAttribute(tag, value) }
            target.setAttribute(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL.toString())
            target.setAttribute(ExifInterface.TAG_IMAGE_WIDTH, "48")
            target.setAttribute(ExifInterface.TAG_IMAGE_LENGTH, "72")
            target.setAttribute(ExifInterface.TAG_PIXEL_X_DIMENSION, "48")
            target.setAttribute(ExifInterface.TAG_PIXEL_Y_DIMENSION, "72")
            target.saveAttributes()
        }
        if (useDescriptor) {
            ParcelFileDescriptor.open(output, ParcelFileDescriptor.MODE_READ_WRITE).use {
                save(ExifInterface(it.fileDescriptor))
            }
        } else {
            save(ExifInterface(output))
        }

        val copied = ExifInterface(output)
        for (tag in listOf(
            ExifInterface.TAG_EXPOSURE_TIME, ExifInterface.TAG_SHUTTER_SPEED_VALUE,
            ExifInterface.TAG_F_NUMBER, ExifInterface.TAG_APERTURE_VALUE, ExifInterface.TAG_FOCAL_LENGTH,
        )) {
            assertNear(original.getAttributeDouble(tag, Double.NaN), copied.getAttributeDouble(tag, Double.NaN), "$tag $label")
        }
        for (tag in listOf(
            ExifInterface.TAG_MAKE, ExifInterface.TAG_MODEL, ExifInterface.TAG_PHOTOGRAPHIC_SENSITIVITY,
            ExifInterface.TAG_FOCAL_LENGTH_IN_35MM_FILM, ExifInterface.TAG_DATETIME_ORIGINAL,
            ExifInterface.TAG_SUBSEC_TIME_ORIGINAL, ExifInterface.TAG_OFFSET_TIME_ORIGINAL,
        )) {
            check(original.getAttribute(tag) == copied.getAttribute(tag)) { "$tag changed: $label" }
        }
        val originalLocation = checkNotNull(original.latLong)
        val copiedLocation = checkNotNull(copied.latLong)
        originalLocation.indices.forEach { assertNear(originalLocation[it], copiedLocation[it], "GPS $label") }
        check(copied.getAttributeInt(ExifInterface.TAG_ORIENTATION, 0) == ExifInterface.ORIENTATION_NORMAL)
        check(copied.getAttributeInt(ExifInterface.TAG_PIXEL_X_DIMENSION, 0) == 48)
        check(copied.getAttributeInt(ExifInterface.TAG_PIXEL_Y_DIMENSION, 0) == 72)
        check(!copied.hasThumbnail())
        val bitmap = checkNotNull(BitmapFactory.decodeFile(output.path))
        try {
            check(bitmap.width == 48 && bitmap.height == 72)
        } finally {
            bitmap.recycle()
        }
        check(output.inputStream().use(PhotoEffectIdentityJpeg::read) == identity) { "Effect identity lost: $label" }
        check(source.readBytes().contentEquals(originalBytes)) { "Source modified: $label" }
    }

    private fun writeJpeg(file: File, width: Int, height: Int, identity: String? = null) {
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        try {
            bitmap.eraseColor(Color.rgb(57, 112, 173))
            val raw = file.outputStream()
            (if (identity == null) raw else PhotoEffectIdentityJpeg.outputStream(raw, identity)).use {
                check(bitmap.compress(Bitmap.CompressFormat.JPEG, 95, it))
            }
        } finally {
            bitmap.recycle()
        }
    }

    private fun assertNear(expected: Double, actual: Double, label: String) {
        check(expected.isFinite() && actual.isFinite() && abs(expected - actual) <= maxOf(abs(expected) * 1e-8, 1e-12)) {
            "$label: expected=$expected actual=$actual"
        }
    }
}
