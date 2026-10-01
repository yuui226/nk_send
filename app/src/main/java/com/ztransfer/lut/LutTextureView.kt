package com.ztransfer.lut

import android.content.Context
import android.graphics.Bitmap
import android.graphics.SurfaceTexture
import android.os.Handler
import android.os.HandlerThread
import android.view.TextureView

/** One GL owner for a monitor page, shared by the old and candidate layers during a switch. */
internal class LutRenderWorker {
    private val thread = HandlerThread("MonitorLut").apply { start() }
    val handler = Handler(thread.looper)
    private var views = 0
    private var closing = false
    fun retainView() { check(!closing); views++ }
    fun releaseView() { check(views > 0); views--; stopIfUnused() }
    fun close() { closing = true; stopIfUnused() }
    private fun stopIfUnused() {
        // Each view queues its GL teardown before releasing its reference. Disposal order between
        // the Compose owner and AndroidView children therefore cannot strand resources.
        if (closing && views == 0) thread.quitSafely()
    }

}

/** Latest-frame mailbox; no per-frame Handler backlog, no ownership of borrowed camera bitmaps. */
internal class LutTextureView(
    context: Context,
    private val worker: LutRenderWorker,
    private val table: CubeLut,
    private val onReady: () -> Unit,
    private val onUnavailable: () -> Unit,
    private val onFailure: (Throwable) -> Unit,
) : TextureView(context), TextureView.SurfaceTextureListener {
    private var renderer: SurfaceRenderer? = null
    private var ownedTexture: SurfaceTexture? = null
    private var lastFrame: Bitmap? = null
    private var released = false
    private var ready = false

    init { isOpaque = false; surfaceTextureListener = this; worker.retainView() }

    fun offer(bitmap: Bitmap) {
        if (released || bitmap === lastFrame) return
        lastFrame = bitmap
        renderer?.offer(bitmap)
    }

    override fun onSurfaceTextureAvailable(texture: SurfaceTexture, width: Int, height: Int) {
        if (released) return
        ready = false
        ownedTexture = texture
        val next = SurfaceRenderer(texture, width, height)
        renderer = next
        lastFrame?.let(next::offer)
    }
    override fun onSurfaceTextureSizeChanged(texture: SurfaceTexture, width: Int, height: Int) {
        renderer?.resize(width, height)
    }
    override fun onSurfaceTextureUpdated(texture: SurfaceTexture) {
        val target = renderer ?: return
        if (!released && !ready && target.presented) {
            ready = true
            onReady()
        }
    }
    override fun onSurfaceTextureDestroyed(texture: SurfaceTexture): Boolean {
        val owned = texture === ownedTexture
        if (owned) {
            if (!released) onUnavailable()
            renderer?.close()
            renderer = null
            ownedTexture = null
            ready = false
        }
        // Renderer releases an owned texture after EGL teardown, off the UI thread.
        return !owned
    }
    fun release() {
        if (released) return
        released = true
        lastFrame = null
        renderer?.close()
        renderer = null
        worker.releaseView()
    }

    private inner class SurfaceRenderer(
        private val texture: SurfaceTexture,
        initialWidth: Int,
        initialHeight: Int,
    ) {
        private val lock = Any()
        private var pending: Bitmap? = null
        private var closed = false
        private var queued = false
        private var dirty = true
        private var surfaceWidth = initialWidth
        private var surfaceHeight = initialHeight
        @Volatile var presented = false
            private set
        private var egl: LutEglSurface? = null
        private var gl: LutGlProgram? = null
        private var uploaded = false

        fun offer(bitmap: Bitmap) = synchronized(lock) {
            if (!closed) { pending = bitmap; schedule() }
        }
        fun resize(width: Int, height: Int) = synchronized(lock) {
            if (!closed) { surfaceWidth = width; surfaceHeight = height; dirty = true; schedule() }
        }
        private fun schedule() {
            if (!queued) { queued = true; worker.handler.post(::draw) }
        }
        private fun draw() {
            val frame: Bitmap?
            val width: Int
            val height: Int
            synchronized(lock) {
                if (closed) { queued = false; return }
                frame = pending; pending = null
                width = surfaceWidth; height = surfaceHeight
                dirty = false
            }
            try {
                if (egl == null) {
                    egl = LutEglSurface().also { it.initialize(texture) }
                    gl = LutGlProgram().also { it.initialize(); it.setLut(table) }
                }
                // Another surface may have been drawn by this same worker since our last frame.
                egl!!.makeCurrent()
                frame?.let { gl!!.upload(it); uploaded = true }
                if (uploaded && width > 0 && height > 0) {
                    gl!!.draw(width, height)
                    presented = true
                    egl!!.swap()
                }
            } catch (failure: Exception) {
                fail(failure)
            } catch (failure: OutOfMemoryError) {
                fail(failure)
            } finally {
                synchronized(lock) {
                    queued = false
                    if (!closed && (pending != null || dirty)) schedule()
                }
            }
        }
        private fun fail(failure: Throwable) {
            close()
            post { if (!released && renderer === this) onFailure(failure) }
        }
        fun close() {
            synchronized(lock) {
                if (closed) return
                closed = true; pending = null
            }
            worker.handler.post {
                try { egl?.makeCurrent(); gl?.close() } catch (_: Exception) { /* lost context */ }
                finally { gl = null; egl?.close(); egl = null; texture.release() }
            }
        }
    }
}
