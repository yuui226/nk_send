package com.ztransfer.crop

import androidx.annotation.Keep
import androidx.exifinterface.media.ExifInterface
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File
import java.io.IOException

/**
 * Serial coefficient transforms; callers own temporary files and publish only after success.
 * Call on a background worker: retain its priority instead of switching native CPU work to IO.
 */
@Keep
internal object LosslessJpeg {
    private val gate = Mutex()
    private val loaded by lazy { System.loadLibrary("ztransfer_crop") }

    suspend fun crop(input: File, output: File, selection: JpegCropSelection) =
        cropResolved(input,output) { selection.resolve(it) }

    suspend fun crop(input: File, output: File, recipe: JpegCropRecipe) =
        cropResolved(input,output) { actual ->
            require(actual == recipe.source) { "Original JPEG geometry changed since crop confirmation" }
            recipe
        }

    private suspend fun cropResolved(input: File, output: File,
        resolve: (JpegCropSource) -> JpegCropRecipe) = gate.withLock {
        require(input.canonicalPath != output.canonicalPath)
        currentCoroutineContext().ensureActive()
        val actual = readSource(input) ?: throw IOException("Incomplete or unsupported original JPEG header")
        val recipe = resolve(actual)
        actual.validate(recipe.rect)
        try {
            loaded
            val r = recipe.rect
            nativeCrop(input.absolutePath, output.absolutePath, actual.width, actual.height,
                actual.mcuWidth, actual.mcuHeight, r.left, r.top, r.width, r.height)
            currentCoroutineContext().ensureActive()
            val from = ExifInterface(input)
            val to = ExifInterface(output)
            for (tag in copiedTags) from.getAttribute(tag)?.let { to.setAttribute(tag, it) }
            // Pixels are not rotated/re-encoded; EXIF describes their display orientation.
            to.setAttribute(ExifInterface.TAG_ORIENTATION, actual.orientation.toString())
            to.setAttribute(ExifInterface.TAG_IMAGE_WIDTH, r.width.toString())
            to.setAttribute(ExifInterface.TAG_IMAGE_LENGTH, r.height.toString())
            to.setAttribute(ExifInterface.TAG_PIXEL_X_DIMENSION, r.width.toString())
            to.setAttribute(ExifInterface.TAG_PIXEL_Y_DIMENSION, r.height.toString())
            to.saveAttributes()
            val result = readSource(output) ?: throw IOException("Invalid cropped JPEG")
            check(result.width == r.width && result.height == r.height && result.orientation == actual.orientation)
            currentCoroutineContext().ensureActive()
        } catch (failure: Throwable) {
            output.delete()
            throw failure
        }
    }

    fun readSource(file: File): JpegCropSource? = file.inputStream().use { stream ->
        parseJpegCropHeader(stream.readBytesBounded(2 * 1024 * 1024))
    }

    private fun java.io.InputStream.readBytesBounded(limit: Int): ByteArray {
        val bytes = ByteArray(limit)
        var used = 0
        while (used < limit) {
            val count = read(bytes, used, limit - used)
            if (count < 0) break
            if (count == 0) continue
            used += count
        }
        return bytes.copyOf(used)
    }

    private external fun nativeCrop(input: String, output: String, width: Int, height: Int,
        mcuWidth: Int, mcuHeight: Int, x: Int, y: Int, cropWidth: Int, cropHeight: Int)

    private val copiedTags = arrayOf(
        ExifInterface.TAG_MAKE, ExifInterface.TAG_MODEL, ExifInterface.TAG_SOFTWARE,
        ExifInterface.TAG_DATETIME, ExifInterface.TAG_DATETIME_ORIGINAL, ExifInterface.TAG_DATETIME_DIGITIZED,
        ExifInterface.TAG_SUBSEC_TIME_ORIGINAL, ExifInterface.TAG_OFFSET_TIME_ORIGINAL,
        ExifInterface.TAG_EXPOSURE_TIME, ExifInterface.TAG_F_NUMBER, ExifInterface.TAG_PHOTOGRAPHIC_SENSITIVITY,
        ExifInterface.TAG_FOCAL_LENGTH, ExifInterface.TAG_FOCAL_LENGTH_IN_35MM_FILM,
        ExifInterface.TAG_LENS_MAKE, ExifInterface.TAG_LENS_MODEL, ExifInterface.TAG_EXPOSURE_PROGRAM,
        ExifInterface.TAG_EXPOSURE_BIAS_VALUE, ExifInterface.TAG_METERING_MODE, ExifInterface.TAG_FLASH,
        ExifInterface.TAG_WHITE_BALANCE, ExifInterface.TAG_COLOR_SPACE,
        ExifInterface.TAG_GPS_VERSION_ID, ExifInterface.TAG_GPS_LATITUDE_REF, ExifInterface.TAG_GPS_LATITUDE,
        ExifInterface.TAG_GPS_LONGITUDE_REF, ExifInterface.TAG_GPS_LONGITUDE,
        ExifInterface.TAG_GPS_ALTITUDE_REF, ExifInterface.TAG_GPS_ALTITUDE,
        ExifInterface.TAG_GPS_TIMESTAMP, ExifInterface.TAG_GPS_DATESTAMP,
        ExifInterface.TAG_GPS_PROCESSING_METHOD, ExifInterface.TAG_GPS_SPEED_REF, ExifInterface.TAG_GPS_SPEED,
        ExifInterface.TAG_GPS_TRACK_REF, ExifInterface.TAG_GPS_TRACK,
    )
}
