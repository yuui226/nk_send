package com.ztransfer.crop

import android.app.Activity
import android.app.Instrumentation
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.os.Bundle
import android.net.Uri
import androidx.exifinterface.media.ExifInterface
import com.ztransfer.util.PhotoCaptureLocation
import kotlinx.coroutines.runBlocking
import java.io.File
import kotlin.math.abs

/** Exercises the actual packaged JNI transform and EXIF rewrite, not a mock encoder. */
class LosslessCropInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) { super.onCreate(arguments); start() }
    override fun onStart() {
        val result = Bundle()
        var code = Activity.RESULT_CANCELED
        val directory = File(targetContext.cacheDir, "crop-native-test").apply { mkdirs() }
        try {
            runBlocking {
                val input = File(directory, "source.jpg")
                val output = File(directory, "crop.jpg")
                val bitmap = Bitmap.createBitmap(256, 192, Bitmap.Config.ARGB_8888)
                // High-frequency detail detects accidental decode/re-encode even at quality=100.
                for (y in 0 until bitmap.height) for (x in 0 until bitmap.width) {
                    bitmap.setPixel(x, y, Color.rgb((x * 31 + y * 11) % 256,
                        (x * 7 + y * 37) % 256, (x * 19 + y * 13) % 256))
                }
                input.outputStream().use { check(bitmap.compress(Bitmap.CompressFormat.JPEG, 91, it)) }
                bitmap.recycle()
                for (orientation in 1..8) {
                    ExifInterface(input).apply {
                        setAttribute(ExifInterface.TAG_ORIENTATION, orientation.toString())
                        setAttribute(ExifInterface.TAG_MAKE, "NIKON")
                        setAttribute(ExifInterface.TAG_MODEL, "Crop fixture")
                        setLatLong(-31.234567, -121.456789)
                        setAltitude(-12.5)
                        setAttribute(ExifInterface.TAG_GPS_DATESTAMP, "2026:10:24")
                        setAttribute(ExifInterface.TAG_GPS_TIMESTAMP, "03:04:05")
                        setAttribute(ExifInterface.TAG_GPS_PROCESSING_METHOD, "GPS")
                        saveAttributes()
                    }
                    val expectedExif = ExifInterface(input)
                    val sourceBytes = input.readBytes()
                    val source = checkNotNull(LosslessJpeg.readSource(input))
                    val crop = CropRect(32, 32, 192, 160)
                    LosslessJpeg.crop(input, output, JpegCropRecipe(source, crop))
                    val directOutput = File(directory, "crop-direct.jpg")
                    val fallback = File(directory, "fallback-source.jpg")
                    withCropSource(targetContext.contentResolver, Uri.fromFile(input), fallback) { alias ->
                        check(alias.path.startsWith("/proc/self/fd/"))
                        check(!fallback.exists())
                        LosslessJpeg.crop(alias, directOutput, JpegCropRecipe(source, crop))
                    }
                    check(output.readBytes().contentEquals(directOutput.readBytes()))
                    assertGpsPreserved(expectedExif, ExifInterface(directOutput), "descriptor orientation=$orientation")
                    check(input.readBytes().contentEquals(sourceBytes)) { "Crop modified original JPEG" }
                    check(!fallback.exists())
                    directOutput.delete()
                    val original = checkNotNull(BitmapFactory.decodeFile(input.path))
                    val cropped = checkNotNull(BitmapFactory.decodeFile(output.path))
                    try {
                        check(cropped.width == crop.width && cropped.height == crop.height)
                        // Chroma interpolation at newly introduced boundaries can legitimately differ.
                        // Every interior decoded pixel must be identical: there was no requantization.
                        for (y in 2 until cropped.height - 2) for (x in 2 until cropped.width - 2) {
                            check(original.getPixel(x + crop.left, y + crop.top) == cropped.getPixel(x, y)) {
                                "JPEG pixel changed at $x,$y; orientation=$orientation"
                            }
                        }
                        val exif = ExifInterface(output)
                        check(exif.getAttributeInt(ExifInterface.TAG_ORIENTATION, 0) == orientation)
                        check(exif.getAttribute(ExifInterface.TAG_MODEL) == "Crop fixture")
                        check(!exif.hasThumbnail())
                        assertGpsPreserved(expectedExif, exif, "file orientation=$orientation")
                    } finally { original.recycle(); cropped.recycle() }
                }
                // Arbitrary right/bottom edges must remain exact (only the origin needs MCU alignment).
                val edgeSource = checkNotNull(LosslessJpeg.readSource(input))
                LosslessJpeg.crop(input, output, JpegCropRecipe(edgeSource, CropRect(32,32,191,159)))
                check(LosslessJpeg.readSource(output)?.let { it.width == 159 && it.height == 127 } == true)
                assertGpsPreserved(ExifInterface(input), ExifInterface(output), "arbitrary edges")
                // APP2 color profiles survive EXIF reconstruction unchanged.
                val originalBytes = input.readBytes()
                if (iccSegments(originalBytes).isEmpty()) {
                    val profile = "ICC_PROFILE\u0000".toByteArray(Charsets.ISO_8859_1) + byteArrayOf(1,1) + ByteArray(132) { it.toByte() }
                    val length = profile.size + 2
                    input.writeBytes(originalBytes.take(2).toByteArray() + byteArrayOf(0xff.toByte(),0xe2.toByte(),
                        (length ushr 8).toByte(),length.toByte()) + profile + originalBytes.drop(2).toByteArray())
                }
                val expectedProfiles = iccSegments(input.readBytes())
                check(expectedProfiles.isNotEmpty())
                val withIcc = checkNotNull(LosslessJpeg.readSource(input))
                LosslessJpeg.crop(input, output, JpegCropRecipe(withIcc, CropRect(32,32,192,160)))
                val actualProfiles = iccSegments(output.readBytes())
                check(expectedProfiles.size == actualProfiles.size && expectedProfiles.zip(actualProfiles).all { (a,b) -> a.contentEquals(b) })
                assertGpsPreserved(ExifInterface(input), ExifInterface(output), "ICC profile")
                // A different camera snapshot must not overwrite readable original GPS.
                val locationFallback = checkNotNull(PhotoCaptureLocation.from(48.8566, 2.3522, -7.25))
                LosslessJpeg.crop(input, output, JpegCropRecipe(withIcc, CropRect(32,32,192,160)), locationFallback)
                assertGpsPreserved(ExifInterface(input), ExifInterface(output), "original wins over fallback")

                // A fresh encoded fixture has no EXIF location at all. Exercise both crop overloads.
                val unlocated = File(directory, "source-without-gps.jpg")
                val plainBitmap = Bitmap.createBitmap(256, 192, Bitmap.Config.ARGB_8888)
                try {
                    plainBitmap.eraseColor(Color.rgb(57, 105, 145))
                    unlocated.outputStream().use { check(plainBitmap.compress(Bitmap.CompressFormat.JPEG, 91, it)) }
                } finally { plainBitmap.recycle() }
                val unlocatedBytes = unlocated.readBytes()
                check(ExifInterface(unlocated).latLong == null)
                val unlocatedSource = checkNotNull(LosslessJpeg.readSource(unlocated))
                val selection = JpegCropSelection(CropBounds(0.125, 0.125, 0.875, 0.875), unlocatedSource.orientation)
                val unlocatedRecipe = selection.resolve(unlocatedSource)
                for (useSelection in listOf(false, true)) {
                    val recovered = File(directory, "recovered-$useSelection.jpg")
                    if (useSelection) LosslessJpeg.crop(unlocated, recovered, selection, locationFallback)
                    else LosslessJpeg.crop(unlocated, recovered, unlocatedRecipe, locationFallback)
                    val recoveredExif = ExifInterface(recovered)
                    val coordinates = checkNotNull(recoveredExif.latLong) { "Fallback GPS missing: selection=$useSelection" }
                    check(abs(coordinates[0] - locationFallback.latitude) <= 1e-8)
                    check(abs(coordinates[1] - locationFallback.longitude) <= 1e-8)
                    check(abs(recoveredExif.getAltitude(Double.NaN) - checkNotNull(locationFallback.altitudeMeters)) <= 1e-8)
                    check(recoveredExif.getAttributeInt(ExifInterface.TAG_GPS_ALTITUDE_REF, -1) == 1)
                    check(recoveredExif.getAttribute(ExifInterface.TAG_GPS_DATESTAMP) == null)
                    check(recoveredExif.getAttribute(ExifInterface.TAG_GPS_TIMESTAMP) == null)

                    val stillUnlocated = File(directory, "without-fallback-$useSelection.jpg")
                    if (useSelection) LosslessJpeg.crop(unlocated, stillUnlocated, selection)
                    else LosslessJpeg.crop(unlocated, stillUnlocated, unlocatedRecipe)
                    val unlocatedExif = ExifInterface(stillUnlocated)
                    check(unlocatedExif.latLong == null) { "Crop invented GPS: selection=$useSelection" }
                    check(unlocatedExif.getAltitude(Double.NaN).isNaN())
                    check(unlocatedExif.getAttribute(ExifInterface.TAG_GPS_LATITUDE) == null)
                    check(unlocatedExif.getAttribute(ExifInterface.TAG_GPS_LONGITUDE) == null)
                    check(unlocated.readBytes().contentEquals(unlocatedBytes)) { "Fallback modified original JPEG" }
                }
                val truncated = File(directory,"truncated.jpg").apply { writeBytes(input.readBytes().take(input.length().toInt()/2).toByteArray()) }
                val rejectedOutput = File(directory,"rejected.jpg")
                check(runCatching { LosslessJpeg.crop(truncated,rejectedOutput,JpegCropRecipe(withIcc,CropRect(32,32,192,160))) }.isFailure)
                check(!rejectedOutput.exists())
                // A queued recipe must never silently adapt to a different source.
                val source = checkNotNull(LosslessJpeg.readSource(input))
                val wrong = JpegCropRecipe(source.copy(width = source.width + 16), CropRect(0,0,64,64))
                check(runCatching { LosslessJpeg.crop(input, File(directory, "wrong.jpg"), wrong) }.isFailure)
                check(!File(directory, "wrong.jpg").exists())
            }
            result.putString("result", "PASS: JNI lossless crop, identical interior pixels, 8 EXIF orientations, GPS preservation/recovery without overwriting or inventing location, source mismatch rejection")
            code = Activity.RESULT_OK
        } catch (failure: Throwable) {
            result.putString("failure", failure.stackTraceToString())
        } finally { directory.deleteRecursively() }
        finish(code, result)
    }

    private fun assertGpsPreserved(expected: ExifInterface, actual: ExifInterface, label: String) {
        val expectedCoordinates = checkNotNull(expected.latLong) { "Fixture GPS missing: $label" }
        val actualCoordinates = checkNotNull(actual.latLong) { "Cropped GPS missing: $label" }
        for (axis in expectedCoordinates.indices) {
            check(abs(expectedCoordinates[axis] - actualCoordinates[axis]) <= 1e-8) { "GPS coordinate changed: $label axis=$axis" }
        }
        val altitude = expected.getAltitude(Double.NaN)
        check(altitude.isFinite() && altitude < 0.0) { "Fixture negative altitude missing: $label" }
        check(abs(altitude - actual.getAltitude(Double.NaN)) <= 1e-8) { "GPS altitude changed: $label" }
        for (tag in listOf(
            ExifInterface.TAG_GPS_LATITUDE_REF, ExifInterface.TAG_GPS_LONGITUDE_REF,
            ExifInterface.TAG_GPS_ALTITUDE_REF, ExifInterface.TAG_GPS_DATESTAMP,
            ExifInterface.TAG_GPS_TIMESTAMP, ExifInterface.TAG_GPS_PROCESSING_METHOD,
        )) {
            val value = checkNotNull(expected.getAttribute(tag)) { "Fixture $tag missing: $label" }
            check(actual.getAttribute(tag) == value) { "$tag changed: $label" }
        }
    }

    private fun iccSegments(bytes:ByteArray):List<ByteArray> {
        val result=mutableListOf<ByteArray>();var at=2
        while(at+4<=bytes.size) {
            val marker=bytes[at+1].toInt() and 255
            if(marker==0xda||marker==0xd9)break
            val length=((bytes[at+2].toInt() and 255) shl 8) or (bytes[at+3].toInt() and 255)
            if(length<2||at+2+length>bytes.size)break
            if(marker==0xe2)result+=bytes.copyOfRange(at,at+2+length)
            at+=2+length
        }
        return result
    }

}
