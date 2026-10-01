package com.ztransfer.lut

import android.app.Activity
import android.app.Instrumentation
import android.graphics.Bitmap
import android.graphics.Color
import android.opengl.EGL14 as EGL
import android.opengl.EGLConfig
import android.opengl.GLES30 as GL
import android.os.Bundle
import java.nio.ByteBuffer
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.roundToInt

/** Offscreen GPU accuracy test. Does not open the tool editor or alter any app preferences. */
class LutColorInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) { super.onCreate(arguments); start() }
    override fun onStart() {
        val result = Bundle()
        val display = EGL.eglGetDisplay(EGL.EGL_DEFAULT_DISPLAY)
        var context = EGL.EGL_NO_CONTEXT
        var surface = EGL.EGL_NO_SURFACE
        var program: LutGlProgram? = null
        var source: Bitmap? = null
        try {
            val version = IntArray(2)
            check(EGL.eglInitialize(display, version, 0, version, 1))
            val configs = arrayOfNulls<EGLConfig>(1)
            val count = IntArray(1)
            check(EGL.eglChooseConfig(display, intArrayOf(
                EGL.EGL_RENDERABLE_TYPE, 0x40, EGL.EGL_SURFACE_TYPE, EGL.EGL_PBUFFER_BIT,
                EGL.EGL_RED_SIZE, 8, EGL.EGL_GREEN_SIZE, 8, EGL.EGL_BLUE_SIZE, 8,
                EGL.EGL_ALPHA_SIZE, 8, EGL.EGL_NONE), 0, configs, 0, 1, count, 0) && count[0] > 0)
            context = EGL.eglCreateContext(display, configs[0], EGL.EGL_NO_CONTEXT,
                intArrayOf(EGL.EGL_CONTEXT_CLIENT_VERSION, 3, EGL.EGL_NONE), 0)
            check(context != EGL.EGL_NO_CONTEXT)
            surface = EGL.eglCreatePbufferSurface(display, configs[0],
                intArrayOf(EGL.EGL_WIDTH, 16, EGL.EGL_HEIGHT, 16, EGL.EGL_NONE), 0)
            check(surface != EGL.EGL_NO_SURFACE)
            check(EGL.eglMakeCurrent(display, surface, surface, context))
            program = LutGlProgram().apply { initialize() }
            val pixels = IntArray(256) { i ->
                Color.rgb(i % 16 * 17, i / 16 * 17, ((i % 16 + 3 * (i / 16)) * 7) % 256)
            }
            source = Bitmap.createBitmap(pixels, 16, 16, Bitmap.Config.ARGB_8888)
            program.upload(source)
            val cases = listOf(
                "identity2" to table(2), "identity17" to table(17),
                "identity33" to table(33), "identity65" to table(65),
                "swap17" to table(17, swap = true),
                "domain17" to table(17, extended = true),
            )
            for ((name, lut) in cases) {
                program.setLut(lut)
                program.draw(16, 16)
                val bytes = ByteBuffer.allocateDirect(16 * 16 * 4)
                GL.glReadPixels(0, 0, 16, 16, GL.GL_RGBA, GL.GL_UNSIGNED_BYTE, bytes)
                check(GL.glGetError() == GL.GL_NO_ERROR)
                var maximum = 0
                for (y in 0 until 16) for (x in 0 until 16) {
                    val pixel = pixels[y * 16 + x]
                    val expected = reference(lut, floatArrayOf(Color.red(pixel) / 255f,
                        Color.green(pixel) / 255f, Color.blue(pixel) / 255f))
                    val offset = ((15 - y) * 16 + x) * 4
                    for (c in 0..2) {
                        val actual = bytes.get(offset + c).toInt() and 255
                        maximum = maxOf(maximum, abs(actual - (expected[c].coerceIn(0f, 1f) * 255).roundToInt()))
                    }
                    check((bytes.get(offset + 3).toInt() and 255) == 255)
                }
                val tolerance = if (name.startsWith("identity")) 1 else 2
                check(maximum <= tolerance) { "$name maximum channel error $maximum > $tolerance" }
                result.putInt(name, maximum)
            }
            check(!source.isRecycled)
            result.putString("renderer", GL.glGetString(GL.GL_RENDERER))
            result.putString("result", "PASS: identity, channel order, domain, interpolation, row orientation, alpha")
            finish(Activity.RESULT_OK, result)
        } catch (failure: Throwable) {
            result.putString("failure", failure.stackTraceToString())
            finish(Activity.RESULT_CANCELED, result)
        } finally {
            try { program?.close() } finally {
                source?.recycle()
                EGL.eglMakeCurrent(display, EGL.EGL_NO_SURFACE, EGL.EGL_NO_SURFACE, EGL.EGL_NO_CONTEXT)
                if (surface != EGL.EGL_NO_SURFACE) EGL.eglDestroySurface(display, surface)
                if (context != EGL.EGL_NO_CONTEXT) EGL.eglDestroyContext(display, context)
                EGL.eglTerminate(display)
                EGL.eglReleaseThread()
            }
        }
    }

    private fun table(size: Int, swap: Boolean = false, extended: Boolean = false): CubeLut {
        val data = FloatArray(size * size * size * 3)
        var index = 0
        for (b in 0 until size) for (g in 0 until size) for (r in 0 until size) {
            val red = r.toFloat() / (size - 1)
            val green = g.toFloat() / (size - 1)
            val blue = b.toFloat() / (size - 1)
            val color = if (extended) floatArrayOf(red * red * 1.4f - .2f, green * blue, blue * .7f + red * .3f)
                else if (swap) floatArrayOf(blue, green, red) else floatArrayOf(red, green, blue)
            for (value in color) data[index++] = value
        }
        return CubeLut(size, if (extended) floatArrayOf(-.1f, .2f, 0f) else floatArrayOf(0f, 0f, 0f),
            if (extended) floatArrayOf(.8f, .9f, 1.2f) else floatArrayOf(1f, 1f, 1f), data, "test")
    }

    /** Independent eight-corner CPU reference, used only in tests, never in the monitor path. */
    private fun reference(lut: CubeLut, input: FloatArray): FloatArray {
        val p = FloatArray(3) { i -> ((input[i] - lut.domainMin[i]) /
            (lut.domainMax[i] - lut.domainMin[i])).coerceIn(0f, 1f) * (lut.size - 1) }
        val lo = IntArray(3) { floor(p[it]).toInt() }
        val fraction = FloatArray(3) { p[it] - lo[it] }
        val result = FloatArray(3)
        for (b in 0..1) for (g in 0..1) for (r in 0..1) {
            val coords = intArrayOf(r, g, b)
            var weight = 1f
            for (c in 0..2) weight *= if (coords[c] == 0) 1 - fraction[c] else fraction[c]
            val index = (((lo[2] + b).coerceAtMost(lut.size - 1) * lut.size +
                (lo[1] + g).coerceAtMost(lut.size - 1)) * lut.size +
                (lo[0] + r).coerceAtMost(lut.size - 1)) * 3
            for (c in 0..2) result[c] += lut.rgb[index + c] * weight
        }
        return result
    }
}
