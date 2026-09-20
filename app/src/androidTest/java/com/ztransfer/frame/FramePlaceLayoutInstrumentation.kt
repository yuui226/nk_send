package com.ztransfer.frame

import android.app.Activity
import android.app.Instrumentation
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.os.Bundle
import java.io.File

/** Run on an emulator with am instrument; writes real renderer contact sheets, without geocoding. */
class FramePlaceLayoutInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) { super.onCreate(arguments); start() }

    override fun onStart() {
        val result = Bundle()
        try {
            val folder = File(targetContext.filesDir, "frame-place-layouts").apply {
                check(isDirectory || mkdirs()) { "Cannot create layout output directory: $absolutePath" }
            }
            for (portrait in listOf(false, true)) {
                val source = Bitmap.createBitmap(if (portrait) 800 else 1200, if (portrait) 1200 else 800, Bitmap.Config.ARGB_8888)
                val photo = Canvas(source)
                photo.drawColor(Color.rgb(114, 146, 157))
                photo.drawCircle(source.width * 0.66f, source.height * 0.35f, source.width * 0.20f,
                    Paint().apply { color = Color.rgb(236, 204, 153) })
                val presets = PhotoFramePreset.entries
                val sheet = Bitmap.createBitmap(1800, ((presets.size + 2) / 3) * 730, Bitmap.Config.ARGB_8888)
                val canvas = Canvas(sheet)
                canvas.drawColor(Color.rgb(215, 215, 215))
                for ((index, preset) in presets.withIndex()) {
                    val metadata = PhotoFrameMetadata("NIKON", "NIKON Z f", "f/2.8", "1/250", "ISO100", "50mm",
                        lensModel = "NIKKOR Z 24-70mm f/2.8 S", dateTime = "2026:09:20 14:32:08",
                        latitude = 30.25, longitude = 120.15, altitudeMeters = 520.0,
                        city = "杭州市", region = "西湖区")
                    val settings = defaultPhotoFrameMetadataSettings(preset).copy(showCity = true, showRegion = true,
                        showCoordinates = true, showAltitude = true, showBrand = true, showModel = true,
                        showLensModel = true, showDate = true, showTime = true, showFocalLength = true, showExposure = true)
                    val output = PhotoFrameExporter.renderPreview(targetContext, source, metadata, preset,
                        PhotoFrameWatermark(), metadataSettings = settings, longEdge = 1200, previewPlaceholders = false)
                    File(folder, "${preset.name}-${if (portrait) "portrait" else "landscape"}.png").outputStream().use {
                        output.compress(Bitmap.CompressFormat.PNG, 100, it)
                    }
                    val scale = minOf(560f / output.width, 670f / output.height)
                    val x = (index % 3) * 600f
                    val y = (index / 3) * 730f
                    canvas.drawText(preset.name, x + 20, y + 26, Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 19f; color = Color.BLACK })
                    canvas.save()
                    canvas.translate(x + (600 - output.width * scale) / 2, y + 42)
                    canvas.scale(scale, scale)
                    canvas.drawBitmap(output, 0f, 0f, Paint(Paint.FILTER_BITMAP_FLAG))
                    canvas.restore()
                    output.recycle()
                }
                File(folder, "sheet-${if (portrait) "portrait" else "landscape"}.png").outputStream().use {
                    sheet.compress(Bitmap.CompressFormat.PNG, 100, it)
                }
                sheet.recycle(); source.recycle()
            }
            result.putString("layouts", folder.absolutePath)
            finish(Activity.RESULT_OK, result)
        } catch (error: Throwable) {
            result.putString("failure", error.stackTraceToString())
            finish(Activity.RESULT_CANCELED, result)
        }
    }
}
