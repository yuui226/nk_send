package com.ztransfer.crop

import androidx.annotation.Keep
import androidx.exifinterface.media.ExifInterface
import com.ztransfer.util.readPhotoCaptureExif
import com.ztransfer.util.PhotoCaptureLocation
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

    suspend fun crop(input: File, output: File, selection: JpegCropSelection,
        locationFallback: PhotoCaptureLocation? = null, trace: ((String) -> Unit)? = null) =
        cropResolved(input, output, locationFallback, trace) { selection.resolve(it) }

    suspend fun crop(input: File, output: File, recipe: JpegCropRecipe,
        locationFallback: PhotoCaptureLocation? = null, trace: ((String) -> Unit)? = null) =
        cropResolved(input, output, locationFallback, trace) { actual ->
            require(actual == recipe.source) { "Original JPEG geometry changed since crop confirmation" }
            recipe
        }

    private suspend fun cropResolved(input: File, output: File,
        locationFallback: PhotoCaptureLocation?, trace: ((String) -> Unit)?,
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
            val sourceLocation = PhotoCaptureLocation.read(from)
            val to = ExifInterface(output)
            for ((tag, value) in readPhotoCaptureExif(from)) to.setAttribute(tag, value)
            val recovered = locationFallback?.fillMissing(to) == true
            trace?.invoke("inputGps=${sourceLocation != null} cameraGps=${locationFallback != null} recovered=$recovered")
            // Pixels are not rotated/re-encoded; EXIF describes their display orientation.
            to.setAttribute(ExifInterface.TAG_ORIENTATION, actual.orientation.toString())
            to.setAttribute(ExifInterface.TAG_IMAGE_WIDTH, r.width.toString())
            to.setAttribute(ExifInterface.TAG_IMAGE_LENGTH, r.height.toString())
            to.setAttribute(ExifInterface.TAG_PIXEL_X_DIMENSION, r.width.toString())
            to.setAttribute(ExifInterface.TAG_PIXEL_Y_DIMENSION, r.height.toString())
            to.saveAttributes()
            val savedLocation = PhotoCaptureLocation.read(ExifInterface(output))
            trace?.invoke("outputGps=${savedLocation != null}")
            check(sourceLocation == null && locationFallback == null || savedLocation != null) {
                "Crop GPS metadata was not preserved"
            }
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
}
