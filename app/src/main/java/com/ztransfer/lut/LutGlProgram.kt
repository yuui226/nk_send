package com.ztransfer.lut

import android.graphics.Bitmap
import android.opengl.GLES30 as GL
import android.opengl.GLUtils
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** All calls, including close(), belong to the owning EGL thread and current context. */
internal class LutGlProgram : AutoCloseable {
    private var program = 0
    private var image = 0
    private var width = 0
    private var height = 0
    private var lutTexture = 0
    private var lut: CubeLut? = null
    private var vao = 0
    private var lowLocation = -1
    private var rangeLocation = -1
    private var sizeLocation = -1
    private var fitLocation = -1

    fun initialize() {
        val max = IntArray(1)
        GL.glGetIntegerv(GL.GL_MAX_3D_TEXTURE_SIZE, max, 0)
        if (max[0] < CubeLutParser.MAX_SIZE) fail("3D texture capacity")
        var vertex = 0
        var fragment = 0
        try {
            vertex = shader(GL.GL_VERTEX_SHADER, VERTEX)
            fragment = shader(GL.GL_FRAGMENT_SHADER, FRAGMENT)
            program = GL.glCreateProgram()
            GL.glAttachShader(program, vertex)
            GL.glAttachShader(program, fragment)
            GL.glLinkProgram(program)
            GL.glGetProgramiv(program, GL.GL_LINK_STATUS, max, 0)
            if (max[0] == 0) fail(GL.glGetProgramInfoLog(program))
            GL.glUseProgram(program)
            GL.glUniform1i(GL.glGetUniformLocation(program, "sourceImage"), 0)
            GL.glUniform1i(GL.glGetUniformLocation(program, "colorTable"), 1)
            lowLocation = GL.glGetUniformLocation(program, "domainLow")
            rangeLocation = GL.glGetUniformLocation(program, "domainScale")
            sizeLocation = GL.glGetUniformLocation(program, "tableSize")
            fitLocation = GL.glGetUniformLocation(program, "fit")
            GL.glGenVertexArrays(1, max, 0)
            vao = max[0]
            image = texture(GL.GL_TEXTURE_2D)
            checkError("initialize")
        } catch (e: Exception) {
            close()
            throw e
        } finally {
            if (vertex != 0) GL.glDeleteShader(vertex)
            if (fragment != 0) GL.glDeleteShader(fragment)
        }
    }

    /** Upload a candidate without changing the current LUT if allocation/upload fails. */
    fun setLut(candidate: CubeLut) {
        var next = 0
        try {
            GL.glActiveTexture(GL.GL_TEXTURE1)
            next = texture(GL.GL_TEXTURE_3D)
            // A single staging buffer; alpha has no effect on color mapping.
            val data = ByteBuffer.allocateDirect(candidate.size * candidate.size * candidate.size * 16)
                .order(ByteOrder.nativeOrder()).asFloatBuffer()
            var index = 0
            while (index < candidate.rgb.size) {
                data.put(candidate.rgb[index++])
                data.put(candidate.rgb[index++])
                data.put(candidate.rgb[index++])
                data.put(1f)
            }
            data.flip()
            GL.glTexImage3D(GL.GL_TEXTURE_3D, 0, GL.GL_RGBA16F, candidate.size, candidate.size,
                candidate.size, 0, GL.GL_RGBA, GL.GL_FLOAT, data)
            checkError("upload LUT")
            val previous = lutTexture
            lutTexture = next
            next = 0
            lut = candidate
            if (previous != 0) GL.glDeleteTextures(1, intArrayOf(previous), 0)
        } finally {
            if (next != 0) GL.glDeleteTextures(1, intArrayOf(next), 0)
        }
    }

    /** Upload borrowed pixels synchronously. Never recycle a Bitmap owned by the monitor. */
    fun upload(bitmap: Bitmap) {
        check(!bitmap.isRecycled)
        // GLUtils uploads component values without Skia's color-space conversion. Refuse an
        // unexpected wide-gamut input instead of silently changing colors under an identity LUT.
        if (bitmap.colorSpace?.isSrgb != true ||
            (bitmap.config != Bitmap.Config.ARGB_8888 && bitmap.config != Bitmap.Config.RGB_565)) {
            throw LutException(LutFailure.INPUT_COLOR, "Expected a supported sRGB monitor bitmap")
        }
        GL.glActiveTexture(GL.GL_TEXTURE0)
        GL.glBindTexture(GL.GL_TEXTURE_2D, image)
        if (width != bitmap.width || height != bitmap.height) {
            GLUtils.texImage2D(GL.GL_TEXTURE_2D, 0, bitmap, 0)
            width = bitmap.width
            height = bitmap.height
        } else {
            GLUtils.texSubImage2D(GL.GL_TEXTURE_2D, 0, 0, 0, bitmap)
        }
        checkError("upload frame")
    }

    fun draw(surfaceWidth: Int, surfaceHeight: Int) {
        val table = checkNotNull(lut)
        check(width > 0 && height > 0 && surfaceWidth > 0 && surfaceHeight > 0)
        GL.glViewport(0, 0, surfaceWidth, surfaceHeight)
        GL.glClearColor(0f, 0f, 0f, 0f)
        GL.glClear(GL.GL_COLOR_BUFFER_BIT)
        GL.glDisable(GL.GL_BLEND)
        GL.glUseProgram(program)
        GL.glBindVertexArray(vao)
        GL.glActiveTexture(GL.GL_TEXTURE0)
        GL.glBindTexture(GL.GL_TEXTURE_2D, image)
        GL.glActiveTexture(GL.GL_TEXTURE1)
        GL.glBindTexture(GL.GL_TEXTURE_3D, lutTexture)
        GL.glUniform3fv(lowLocation, 1, table.domainMin, 0)
        GL.glUniform3f(rangeLocation,
            1f / (table.domainMax[0] - table.domainMin[0]),
            1f / (table.domainMax[1] - table.domainMin[1]),
            1f / (table.domainMax[2] - table.domainMin[2]))
        GL.glUniform1f(sizeLocation, table.size.toFloat())
        val imageRatio = width.toFloat() / height
        val viewRatio = surfaceWidth.toFloat() / surfaceHeight
        GL.glUniform2f(fitLocation, minOf(1f, imageRatio / viewRatio), minOf(1f, viewRatio / imageRatio))
        GL.glDrawArrays(GL.GL_TRIANGLE_STRIP, 0, 4)
        checkError("draw")
    }

    override fun close() {
        if (image != 0) GL.glDeleteTextures(1, intArrayOf(image), 0)
        if (lutTexture != 0) GL.glDeleteTextures(1, intArrayOf(lutTexture), 0)
        if (program != 0) GL.glDeleteProgram(program)
        if (vao != 0) GL.glDeleteVertexArrays(1, intArrayOf(vao), 0)
        image = 0; lutTexture = 0; program = 0; vao = 0
        width = 0; height = 0; lut = null
    }

    private fun texture(target: Int): Int {
        val ids = IntArray(1)
        GL.glGenTextures(1, ids, 0)
        GL.glBindTexture(target, ids[0])
        GL.glTexParameteri(target, GL.GL_TEXTURE_MIN_FILTER, GL.GL_LINEAR)
        GL.glTexParameteri(target, GL.GL_TEXTURE_MAG_FILTER, GL.GL_LINEAR)
        GL.glTexParameteri(target, GL.GL_TEXTURE_WRAP_S, GL.GL_CLAMP_TO_EDGE)
        GL.glTexParameteri(target, GL.GL_TEXTURE_WRAP_T, GL.GL_CLAMP_TO_EDGE)
        if (target == GL.GL_TEXTURE_3D) GL.glTexParameteri(target, GL.GL_TEXTURE_WRAP_R, GL.GL_CLAMP_TO_EDGE)
        return ids[0]
    }

    private fun shader(type: Int, source: String): Int {
        val id = GL.glCreateShader(type)
        GL.glShaderSource(id, source)
        GL.glCompileShader(id)
        val success = IntArray(1)
        GL.glGetShaderiv(id, GL.GL_COMPILE_STATUS, success, 0)
        if (success[0] == 0) {
            val message = GL.glGetShaderInfoLog(id)
            GL.glDeleteShader(id)
            fail(message)
        }
        return id
    }

    private fun checkError(stage: String) {
        val error = GL.glGetError()
        if (error != GL.GL_NO_ERROR) fail("$stage: GL $error")
    }
    private fun fail(message: String): Nothing = throw LutException(LutFailure.GPU, message)

    private companion object {
        const val VERTEX = """#version 300 es
            precision highp float;
            uniform vec2 fit;
            out vec2 uv;
            void main() {
                vec2 p = vec2(float(gl_VertexID & 1), float(gl_VertexID >> 1));
                uv = vec2(p.x, 1.0 - p.y);
                gl_Position = vec4((p * 2.0 - 1.0) * fit, 0.0, 1.0);
            }
        """
        const val FRAGMENT = """#version 300 es
            precision highp float;
            precision highp sampler3D;
            uniform sampler2D sourceImage;
            uniform sampler3D colorTable;
            uniform vec3 domainLow;
            uniform vec3 domainScale;
            uniform float tableSize;
            in vec2 uv;
            out vec4 outputColor;
            void main() {
                vec4 source = texture(sourceImage, uv);
                vec3 inputColor = clamp((source.rgb - domainLow) * domainScale, 0.0, 1.0);
                vec3 coordinate = (inputColor * (tableSize - 1.0) + 0.5) / tableSize;
                outputColor = vec4(clamp(texture(colorTable, coordinate).rgb, 0.0, 1.0), source.a);
            }
        """
    }
}
