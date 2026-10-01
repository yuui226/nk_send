package com.ztransfer.lut

import android.graphics.SurfaceTexture
import android.opengl.EGL14 as EGL
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface

/** Owned by one rendering thread. No UI thread waits on EGL teardown or buffer swaps. */
internal class LutEglSurface : AutoCloseable {
    private var display: EGLDisplay = EGL.EGL_NO_DISPLAY
    private var context: EGLContext = EGL.EGL_NO_CONTEXT
    private var surface: EGLSurface = EGL.EGL_NO_SURFACE

    fun initialize(texture: SurfaceTexture) {
        try {
            display = LutEglDisplay.acquire()
            val configs = arrayOfNulls<EGLConfig>(1)
            val count = IntArray(1)
            val attributes = intArrayOf(
                EGL.EGL_RENDERABLE_TYPE, 0x0040, // EGL_OPENGL_ES3_BIT_KHR
                EGL.EGL_SURFACE_TYPE, EGL.EGL_WINDOW_BIT,
                EGL.EGL_RED_SIZE, 8, EGL.EGL_GREEN_SIZE, 8, EGL.EGL_BLUE_SIZE, 8,
                EGL.EGL_ALPHA_SIZE, 8, EGL.EGL_DEPTH_SIZE, 0, EGL.EGL_STENCIL_SIZE, 0,
                EGL.EGL_NONE,
            )
            requireEgl(EGL.eglChooseConfig(display, attributes, 0, configs, 0, 1, count, 0) && count[0] > 0, "config")
            context = EGL.eglCreateContext(display, configs[0], EGL.EGL_NO_CONTEXT,
                intArrayOf(EGL.EGL_CONTEXT_CLIENT_VERSION, 3, EGL.EGL_NONE), 0)
            requireEgl(context != EGL.EGL_NO_CONTEXT, "GLES 3 context")
            surface = EGL.eglCreateWindowSurface(display, configs[0], texture, intArrayOf(EGL.EGL_NONE), 0)
            requireEgl(surface != EGL.EGL_NO_SURFACE, "window surface")
            requireEgl(EGL.eglMakeCurrent(display, surface, surface, context), "make current")
        } catch (e: Exception) {
            close()
            throw e
        }
    }

    fun makeCurrent() { requireEgl(EGL.eglMakeCurrent(display, surface, surface, context), "make current") }

    fun swap() { requireEgl(EGL.eglSwapBuffers(display, surface), "swap buffers") }

    override fun close() {
        if (display != EGL.EGL_NO_DISPLAY) {
            EGL.eglMakeCurrent(display, EGL.EGL_NO_SURFACE, EGL.EGL_NO_SURFACE, EGL.EGL_NO_CONTEXT)
            if (surface != EGL.EGL_NO_SURFACE) EGL.eglDestroySurface(display, surface)
            if (context != EGL.EGL_NO_CONTEXT) EGL.eglDestroyContext(display, context)
            LutEglDisplay.release(display)
        }
        surface = EGL.EGL_NO_SURFACE
        context = EGL.EGL_NO_CONTEXT
        display = EGL.EGL_NO_DISPLAY
    }

    private fun requireEgl(success: Boolean, operation: String) {
        if (!success) throw LutException(LutFailure.GPU, "$operation: EGL ${EGL.eglGetError()}")
    }
}

/** Candidate and current surfaces can coexist. Releasing one must not terminate the other. */
private object LutEglDisplay {
    private var users = 0
    private var display: EGLDisplay = EGL.EGL_NO_DISPLAY
    @Synchronized fun acquire(): EGLDisplay {
        if (users == 0) {
            val next = EGL.eglGetDisplay(EGL.EGL_DEFAULT_DISPLAY)
            val version = IntArray(2)
            if (next == EGL.EGL_NO_DISPLAY || !EGL.eglInitialize(next, version, 0, version, 1)) {
                throw LutException(LutFailure.GPU, "EGL display unavailable")
            }
            display = next
        }
        users++
        return display
    }
    @Synchronized fun release(value: EGLDisplay) {
        check(users > 0 && value == display)
        if (--users == 0) {
            EGL.eglTerminate(display)
            display = EGL.EGL_NO_DISPLAY
        }
    }
}
