package com.ztransfer.recorder

import android.annotation.SuppressLint
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaRecorder
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.util.Log
import androidx.compose.ui.graphics.ImageBitmap
import java.io.File
import java.nio.ByteBuffer
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlin.concurrent.thread

/**
 * 录像输出去向。两条路径：
 * - [AppDir]：应用私有目录（未配置传输目录时的回退，行为同旧版）。
 * - [Saf]：调用方已在用户的 SAF 传输目录里建好文档并打开 "rw" 描述符,
 *   录制期间由 recorder 持有该 pfd，stop()/release 时恰好关闭一次。
 */
sealed interface RecordingSink {
    class AppDir(val dir: File) : RecordingSink
    class Saf(val pfd: ParcelFileDescriptor, val displayName: String) : RecordingSink
}

/**
 * Records live viewfinder frames (ImageBitmap) into an MP4/H.264 video file using
 * Android's MediaCodec + MediaMuxer. Captures whatever frames are being displayed
 * in the viewfinder -- independent of camera hardware performance.
 *
 * 帧驱动 VFR：调用方在每个【新】帧到达时调一次 [encodeFrame] 并携带该帧的到达
 * 时间戳（elapsedRealtime 纳秒），PTS 按真实到达时刻写入——有线 ~70fps 与无线
 * ~20fps 都按实际帧率成片，不补帧也不丢帧。
 *
 * 可选麦克风音轨（[withAudio]）：AAC-LC 44.1kHz 单声道，与视频共用同一挂钟基准
 * 和暂停累计，A/V 同步且暂停对两轨同时生效。音频初始化失败只降级为无声，
 * 绝不让录像整体失败。
 *
 * Usage:
 *   recorder.start()
 *   recorder.encodeFrame(bitmap, frameTimeNs)  // 每个新帧一次，IO/Default 线程
 *   recorder.pause() / resume()
 *   val name = recorder.stop()   // 成片文件名，null 表示失败
 */
class ViewfinderRecorder(
    private val sink: RecordingSink,
    private val srcWidth: Int,
    private val srcHeight: Int,
    private val frameRate: Int = 60,
    private val withAudio: Boolean = false,
    private val preferredAudioInput: AudioDeviceInfo? = null
) {
    // 编码尺寸向下取偶：YUV420 色度按 2x2 块下采样，奇数宽高会让转换时数组越界。
    // 帧尺寸校验仍按 srcWidth/srcHeight 比对，取像素时只读左上角偶数区域。
    private val width = srcWidth and -2
    private val height = srcHeight and -2

    @Volatile
    var isRecording: Boolean = false
        private set

    @Volatile
    var isPaused: Boolean = false
        private set

    private var videoCodec: MediaCodec? = null
    private var audioCodec: MediaCodec? = null
    private var audioRecord: AudioRecord? = null
    private var audioThread: Thread? = null
    private var muxer: MediaMuxer? = null
    private var pfd: ParcelFileDescriptor? = null    // SAF 模式持有；releaseInternal 关闭一次
    private var displayName: String? = null
    private val videoBufferInfo = MediaCodec.BufferInfo()   // 仅视频编码线程使用
    private val audioBufferInfo = MediaCodec.BufferInfo()   // 仅音频线程使用

    // ---- 双轨 muxer 状态：全部在 muxerLock 下读写 -------------------------
    // 经典双轨竞态：muxer.start() 必须等两条轨的 INFO_OUTPUT_FORMAT_CHANGED 都
    // 到齐之后；之前产出的编码数据先暂存，start 后按轨原序冲刷。
    private val muxerLock = Any()
    private var videoTrack = -1
    private var audioTrack = -1
    @Volatile
    private var muxerStarted: Boolean = false
    private class PendingSample(val data: ByteArray, val ptsUs: Long, val flags: Int)
    private val pendingVideo = ArrayDeque<PendingSample>()
    private val pendingAudio = ArrayDeque<PendingSample>()
    private var pendingBytes = 0

    // 音轨是否参与本次录制（权限被拒/设备初始化失败时为 false，纯视频）。
    @Volatile
    private var audioEnabled = false
    @Volatile
    private var audioStopRequested = false

    // PTS 时钟：统一用 SystemClock.elapsedRealtimeNanos()（取景帧的
    // receivedAtElapsedMs 也是这个时钟），视频按帧的真实到达时刻、音频按采集
    // 时刻取值，共用 base 与暂停累计——A/V 天然同步，暂停对两轨同一刀切。
    private val ptsLock = Any()
    private var baseTimeNs: Long = 0L
    private var pausedTotalNs: Long = 0L
    private var pauseStartNs: Long = 0L
    private var lastVideoPtsUs: Long = -1L   // 仅视频编码线程访问
    private var lastAudioPtsUs: Long = -1L   // 仅音频线程访问

    private var yuvBuffer: ByteArray? = null
    private var pixelBuffer: IntArray? = null

    // ---- public API -------------------------------------------------------

    /**
     * Initialise the H.264 encoder and MP4 muxer (plus AAC encoder + AudioRecord
     * when [withAudio]). Returns true on success. 失败时内部资源（含 SAF pfd）
     * 已全部释放。
     */
    fun start(): Boolean {
        // SAF pfd 所有权在构造 recorder 时即转移过来：先记到字段上，
        // 后续任何失败路径都由 releaseInternal 统一关闭，恰好一次。
        if (sink is RecordingSink.Saf) {
            this.pfd = sink.pfd
            this.displayName = sink.displayName
        }
        return try {
            val encoderName = findEncoder()
            if (encoderName == null) {
                Log.e(TAG, "No H.264 encoder found")
                releaseInternal()
                return false
            }

            val codec = MediaCodec.createByCodecName(encoderName)
            val format = MediaFormat.createVideoFormat(MIME_TYPE, width, height).apply {
                setInteger(MediaFormat.KEY_COLOR_FORMAT,
                    MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
                setInteger(MediaFormat.KEY_BIT_RATE, bitRate(width, height, frameRate))
                setInteger(MediaFormat.KEY_FRAME_RATE, frameRate)
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            }
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            codec.start()
            this.videoCodec = codec

            // 输出：SAF 描述符（用户传输目录，相册可见）或应用私有目录文件。
            when (sink) {
                is RecordingSink.Saf -> {
                    this.muxer = MediaMuxer(sink.pfd.fileDescriptor,
                        MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
                }
                is RecordingSink.AppDir -> {
                    sink.dir.mkdirs()
                    val file = File(sink.dir, newFileName())
                    this.muxer = MediaMuxer(file.absolutePath,
                        MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
                    this.displayName = file.name
                }
            }

            this.videoTrack = -1
            this.audioTrack = -1
            this.muxerStarted = false
            this.pendingVideo.clear()
            this.pendingAudio.clear()
            this.pendingBytes = 0
            // base 定在开录一刻：先于任何视频帧/音频块的 PTS 计算，
            // 两条轨从同一原点起算。
            this.baseTimeNs = SystemClock.elapsedRealtimeNanos()
            this.pausedTotalNs = 0L
            this.pauseStartNs = 0L
            this.lastVideoPtsUs = -1L
            this.lastAudioPtsUs = -1L
            this.audioStopRequested = false
            this.audioEnabled = false
            this.yuvBuffer = ByteArray(width * height * 3 / 2)
            this.pixelBuffer = IntArray(width * height)

            // 音频只降级不致命：无权限/无麦克风/编码器缺失都退成无声录像。
            if (withAudio) initAudio()

            this.isRecording = true
            this.isPaused = false

            if (audioEnabled) {
                audioThread = thread(name = "vf-audio") { audioLoop() }
            }

            Log.d(TAG, "Started recording → ${displayName} (${width}x${height}, " +
                    "sink=${if (sink is RecordingSink.Saf) "SAF" else "appDir"}, audio=$audioEnabled)")
            true
        } catch (e: Exception) {
            Log.e(TAG, "start failed", e)
            releaseInternal()
            false
        }
    }

    /**
     * Convert [bitmap] to YUV420p, push to the encoder, and drain any pending
     * output into the muxer. Call on an IO thread for best throughput.
     * Returns true if the frame was queued successfully.
     *
     * 帧驱动 VFR：[frameTimeNs] 传该帧的到达时刻（SystemClock.elapsedRealtimeNanos
     * 时钟，即 receivedAtElapsedMs * 1_000_000），PTS 按它落盘；传负值退回取当前
     * 时刻（兼容无时间戳来源）。
     */
    fun encodeFrame(bitmap: ImageBitmap, frameTimeNs: Long = -1L): Boolean {
        val c = videoCodec ?: return false
        if (!isRecording) return false
        if (bitmap.width != srcWidth || bitmap.height != srcHeight) {
            Log.w(TAG, "Frame size mismatch: expected ${srcWidth}x${srcHeight}, got ${bitmap.width}x${bitmap.height}")
            return false
        }
        if (isPaused) return true  // 暂停中不喂帧；PTS 由挂钟扣除暂停时段保证连续

        return try {
            // Drain output before feeding input, keeping the encoder pipeline flowing.
            drainVideo(c)

            // Convert and feed.
            argbToYuv420(bitmap)
            val buf = yuvBuffer ?: return false
            val pts = computeVideoPts(frameTimeNs)

            val inputIndex = c.dequeueInputBuffer(INPUT_TIMEOUT_US)
            if (inputIndex >= 0) {
                // 优先按编码器给出的平面布局写入（Image 携带 rowStride/pixelStride）：
                // 硬件编码器常要求 NV12 或带对齐的 stride，直接塞紧凑 I420 会花屏/偏色。
                val image = c.getInputImage(inputIndex)
                if (image != null) {
                    writeToImage(image, buf)
                    c.queueInputBuffer(inputIndex, 0, width * height * 3 / 2, pts, 0)
                } else {
                    val inputBuffer = c.getInputBuffer(inputIndex) ?: return false
                    inputBuffer.clear()
                    inputBuffer.put(buf)
                    c.queueInputBuffer(inputIndex, 0, buf.size, pts, 0)
                }
                true
            } else {
                // Encoder is busy; skip this frame rather than blocking.
                true
            }
        } catch (e: Exception) {
            Log.e(TAG, "encodeFrame error", e)
            false
        }
    }

    /** Pause recording -- the file stays open but frames are skipped. */
    fun pause() {
        if (!isPaused) {
            synchronized(ptsLock) { pauseStartNs = SystemClock.elapsedRealtimeNanos() }
            isPaused = true
        }
    }

    /** Resume recording after a pause. */
    fun resume() {
        if (isPaused) {
            synchronized(ptsLock) {
                pausedTotalNs += SystemClock.elapsedRealtimeNanos() - pauseStartNs
            }
            isPaused = false
        }
    }

    /**
     * Finalise both encoders and the muxer, then return the completed file's
     * display name. Returns null if recording never produced a playable file.
     */
    fun stop(): String? {
        if (!isRecording) return displayName
        isRecording = false
        isPaused = false
        val name = displayName

        return try {
            // 音频先收尾：置停止旗标，线程内部送 EOS 并限时排空后自行退出；
            // join 设上限——音频卡死也不能把 stop() 拖死。
            audioStopRequested = true
            audioThread?.join(4_000)

            val c = videoCodec
            if (c != null) {
                // 送 EOS 限次重试：编码器一直繁忙时也不能无限等，
                // 否则 stop() 挂死、界面永远停在"录制中"。
                var queuedEos = false
                var attempts = 0
                while (!queuedEos && attempts < 5) {
                    val inputIndex = c.dequeueInputBuffer(EOS_TIMEOUT_US)
                    if (inputIndex >= 0) {
                        c.queueInputBuffer(inputIndex, 0, 0, 0,
                            MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        queuedEos = true
                    }
                    attempts++
                }
                // Drain until EOS (内部另有 2s 兜底超时).
                drainVideo(c, endOfStream = queuedEos)
            }
            // muxer 从未启动（一帧都没写成）说明文件是空壳，按失败上报。
            if (muxerStarted) name else null
        } catch (e: Exception) {
            Log.e(TAG, "stop error", e)
            // Return the name anyway -- the file may be partially playable.
            if (muxerStarted) name else null
        } finally {
            releaseInternal()
        }
    }

    // ---- internal: audio --------------------------------------------------

    /**
     * 初始化 AudioRecord + AAC 编码器。任何失败（无 RECORD_AUDIO 权限、设备无
     * 麦克风、编码器缺失）只置 audioEnabled=false 退成无声，不抛出。
     */
    @SuppressLint("MissingPermission")
    private fun initAudio() {
        try {
            val minBuf = AudioRecord.getMinBufferSize(
                AUDIO_SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
            if (minBuf <= 0) {
                Log.w(TAG, "AudioRecord.getMinBufferSize failed: $minBuf, video-only")
                return
            }
            val rec = AudioRecord(
                MediaRecorder.AudioSource.MIC,
                AUDIO_SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                maxOf(minBuf * 2, 8192)
            )
            if (rec.state != AudioRecord.STATE_INITIALIZED) {
                Log.w(TAG, "AudioRecord not initialised, video-only")
                rec.release()
                return
            }
            val preferredInput = preferredAudioInput
            if (preferredInput != null) {
                val preferred = rec.setPreferredDevice(preferredInput)
                Log.d(
                    TAG,
                    "Built-in mic preference: accepted=$preferred " +
                        "id=${preferredInput.id} type=${preferredInput.type}"
                )
            } else {
                Log.w(TAG, "No TYPE_BUILTIN_MIC input found; using system audio input route")
            }

            val format = MediaFormat.createAudioFormat(AUDIO_MIME_TYPE, AUDIO_SAMPLE_RATE, 1).apply {
                setInteger(MediaFormat.KEY_AAC_PROFILE,
                    MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                setInteger(MediaFormat.KEY_BIT_RATE, AUDIO_BIT_RATE)
                setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16384)
            }
            val ac = MediaCodec.createEncoderByType(AUDIO_MIME_TYPE)
            ac.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            ac.start()

            rec.startRecording()
            // 权限被 AppOps 静默拦截时构造不抛异常，但 startRecording 后仍非在录态。
            if (rec.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
                Log.w(TAG, "AudioRecord failed to start recording, video-only")
                rec.release()
                runCatching { ac.stop() }
                ac.release()
                return
            }
            val routedInput = rec.routedDevice
            Log.d(
                TAG,
                "Audio input routed: id=${routedInput?.id} type=${routedInput?.type} " +
                    "builtIn=${routedInput?.type == AudioDeviceInfo.TYPE_BUILTIN_MIC}"
            )

            this.audioRecord = rec
            this.audioCodec = ac
            this.audioEnabled = true
        } catch (e: Exception) {
            Log.w(TAG, "audio init failed, falling back to video-only", e)
            runCatching { audioRecord?.release() }
            audioRecord = null
            runCatching { audioCodec?.release() }
            audioCodec = null
            audioEnabled = false
        }
    }

    /**
     * 音频线程主循环：读麦克风 PCM → 喂 AAC 编码器 → 排空进 muxer。
     * 暂停期间照常把麦克风数据读走但丢弃（防积压陈旧音频），PTS 不前进——
     * 恢复后由挂钟扣除暂停累计，与视频轨同一刀切、无漂移。
     */
    private fun audioLoop() {
        val ac = audioCodec ?: return
        val rec = audioRecord ?: return
        val chunk = ByteArray(AUDIO_CHUNK_BYTES)
        try {
            while (isRecording && !audioStopRequested) {
                val n = rec.read(chunk, 0, chunk.size)
                if (n <= 0) {
                    // 设备错误（ERROR_INVALID_OPERATION 等）：稍等重试，不空转烧 CPU。
                    Thread.sleep(10)
                    continue
                }
                if (isPaused) continue   // 读走即丢，见函数注释

                val inIdx = ac.dequeueInputBuffer(INPUT_TIMEOUT_US)
                if (inIdx >= 0) {
                    val ib = ac.getInputBuffer(inIdx)
                    if (ib != null) {
                        ib.clear()
                        ib.put(chunk, 0, n)
                        ac.queueInputBuffer(inIdx, 0, n, computeAudioPts(), 0)
                    } else {
                        ac.queueInputBuffer(inIdx, 0, 0, 0, 0)
                    }
                }
                // else: 编码器忙，丢弃本块——挂钟 PTS 下留个空隙，不失同步。
                drainAudio(ac)
            }

            // EOS：与视频同一套限次 + 限时排空纪律。
            var queuedEos = false
            var attempts = 0
            while (!queuedEos && attempts < 5) {
                val idx = ac.dequeueInputBuffer(EOS_TIMEOUT_US)
                if (idx >= 0) {
                    ac.queueInputBuffer(idx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                    queuedEos = true
                }
                attempts++
            }
            drainAudio(ac, endOfStream = queuedEos)
        } catch (e: Exception) {
            Log.e(TAG, "audio loop error", e)
            // 音轨中途死掉：若 muxer 还没启动，放弃音轨让视频轨能开写，
            // 否则整段录像会被"永远等不到的音频格式"卡成空文件。
            abandonAudioTrack()
        }
    }

    /** 音轨异常退出时调用：muxer 未启动则改按纯视频启动条件放行。 */
    private fun abandonAudioTrack() {
        synchronized(muxerLock) {
            if (muxerStarted) return
            audioEnabled = false
            pendingBytes -= pendingAudio.sumOf { it.data.size }
            pendingAudio.clear()
            val m = muxer ?: return
            maybeStartMuxerLocked(m)
        }
    }

    // ---- internal: PTS ----------------------------------------------------

    /** 距开录的微秒数（扣除暂停累计），elapsedRealtime 时钟。 */
    private fun elapsedUs(): Long {
        val now = SystemClock.elapsedRealtimeNanos()
        synchronized(ptsLock) {
            return (now - baseTimeNs - pausedTotalNs) / 1_000L
        }
    }

    // 视频 PTS：按帧真实到达时刻（扣除暂停累计）生成，保证严格递增。
    // 开录前已在屏上的首帧到达时刻早于 base，经递增钳制落到 ~0，语义正确。
    private fun computeVideoPts(frameTimeNs: Long): Long {
        var pts = if (frameTimeNs > 0) {
            synchronized(ptsLock) { (frameTimeNs - baseTimeNs - pausedTotalNs) / 1_000L }
        } else {
            elapsedUs()
        }
        if (pts <= lastVideoPtsUs) pts = lastVideoPtsUs + 1_000L
        lastVideoPtsUs = pts
        return pts
    }

    // 音频 PTS：按采集时刻取挂钟，与视频共用 base/暂停累计，保证严格递增。
    private fun computeAudioPts(): Long {
        var pts = elapsedUs()
        if (pts <= lastAudioPtsUs) pts = lastAudioPtsUs + 1L
        lastAudioPtsUs = pts
        return pts
    }

    // ---- internal: muxer（双轨竞态的集中处理点）---------------------------

    /**
     * 编码器输出格式就绪：加轨；两条轨（或纯视频一条）都就绪后才 start muxer
     * 并冲刷暂存样本。muxer.start() 之前 writeSampleData 会直接崩，这里是唯一
     * 的启动闸门。
     */
    private fun onEncoderFormat(isAudio: Boolean, format: MediaFormat) {
        synchronized(muxerLock) {
            val m = muxer ?: return
            if (muxerStarted) return
            if (isAudio) {
                if (audioTrack < 0 && audioEnabled) audioTrack = m.addTrack(format)
            } else {
                if (videoTrack < 0) videoTrack = m.addTrack(format)
            }
            maybeStartMuxerLocked(m)
        }
    }

    private fun maybeStartMuxerLocked(m: MediaMuxer) {
        if (muxerStarted) return
        if (videoTrack < 0) return
        if (audioEnabled && audioTrack < 0) return
        m.start()
        muxerStarted = true
        // 冲刷暂存：每条轨内部保持入队顺序，PTS 单调性不被破坏。
        val info = MediaCodec.BufferInfo()
        for (s in pendingVideo) {
            info.set(0, s.data.size, s.ptsUs, s.flags)
            m.writeSampleData(videoTrack, ByteBuffer.wrap(s.data), info)
        }
        if (audioTrack >= 0) {
            for (s in pendingAudio) {
                info.set(0, s.data.size, s.ptsUs, s.flags)
                m.writeSampleData(audioTrack, ByteBuffer.wrap(s.data), info)
            }
        }
        pendingVideo.clear()
        pendingAudio.clear()
        pendingBytes = 0
    }

    /**
     * 写一个编码样本。muxer 已启动直接写；未启动（另一条轨格式未到）先复制暂存，
     * 总量设上限防对端异常时内存无限涨。视频/音频线程都会走到这里，muxerLock
     * 同时兼作 MediaMuxer 的跨线程串行化锁。
     */
    private fun writeSample(isAudio: Boolean, buffer: ByteBuffer, info: MediaCodec.BufferInfo) {
        synchronized(muxerLock) {
            val m = muxer ?: return
            if (muxerStarted) {
                val track = if (isAudio) audioTrack else videoTrack
                if (track < 0) return   // 该轨已被放弃
                m.writeSampleData(track, buffer, info)
            } else {
                if (pendingBytes + info.size > PENDING_CAP_BYTES) {
                    Log.w(TAG, "pending sample cap exceeded, dropping ${if (isAudio) "audio" else "video"} sample")
                    return
                }
                val copy = ByteArray(info.size)
                buffer.get(copy)
                pendingBytes += info.size
                (if (isAudio) pendingAudio else pendingVideo)
                    .add(PendingSample(copy, info.presentationTimeUs, info.flags))
            }
        }
    }

    // ---- internal: encoders -----------------------------------------------

    private fun findEncoder(): String? {
        // Prefer the Google software encoder for consistent behaviour.
        val soft = "OMX.google.h264.encoder"
        if (hasCodec(soft)) return soft
        // Fall back to any available H.264 encoder.
        val codecList = MediaCodecList(MediaCodecList.ALL_CODECS)
        for (info in codecList.codecInfos) {
            if (!info.isEncoder) continue
            for (mime in info.supportedTypes) {
                if (mime.equals(MIME_TYPE, ignoreCase = true))
                    return info.name
            }
        }
        return null
    }

    private fun hasCodec(name: String): Boolean {
        val list = MediaCodecList(MediaCodecList.ALL_CODECS)
        return list.codecInfos.any { it.name == name }
    }

    /**
     * Drain encoded video output from the codec and feed it into the muxer.
     * When [endOfStream] is true, loops until BUFFER_FLAG_END_OF_STREAM is seen.
     */
    private fun drainVideo(c: MediaCodec, endOfStream: Boolean = false) {
        // EOS 排空设 2s 硬上限：编码器异常不吐 EOS 时不能把 stop() 拖死。
        val deadlineNs = System.nanoTime() + 2_000_000_000L
        while (true) {
            val index = c.dequeueOutputBuffer(videoBufferInfo, DRAIN_TIMEOUT_US)
            when {
                index >= 0 -> {
                    val outputBuffer = c.getOutputBuffer(index) ?: continue
                    if (videoBufferInfo.size > 0) {
                        if (videoBufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                            // CSD is handled by the muxer internally; skip.
                        } else {
                            outputBuffer.position(videoBufferInfo.offset)
                            outputBuffer.limit(videoBufferInfo.offset + videoBufferInfo.size)
                            writeSample(isAudio = false, buffer = outputBuffer, info = videoBufferInfo)
                        }
                    }
                    c.releaseOutputBuffer(index, false)
                    if (videoBufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                        return
                    }
                }
                index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    onEncoderFormat(isAudio = false, format = c.outputFormat)
                }
                index == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                    if (!endOfStream) break
                    if (System.nanoTime() > deadlineNs) {
                        Log.w(TAG, "drainVideo: EOS drain timed out")
                        return
                    }
                }
                else -> break
            }
        }
    }

    /** 音频排空：与 drainVideo 同一套纪律（限时 EOS 兜底），跑在音频线程。 */
    private fun drainAudio(c: MediaCodec, endOfStream: Boolean = false) {
        val deadlineNs = System.nanoTime() + 2_000_000_000L
        while (true) {
            val index = c.dequeueOutputBuffer(audioBufferInfo, DRAIN_TIMEOUT_US)
            when {
                index >= 0 -> {
                    val outputBuffer = c.getOutputBuffer(index) ?: continue
                    if (audioBufferInfo.size > 0) {
                        if (audioBufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                            // CSD is handled by the muxer internally; skip.
                        } else {
                            outputBuffer.position(audioBufferInfo.offset)
                            outputBuffer.limit(audioBufferInfo.offset + audioBufferInfo.size)
                            writeSample(isAudio = true, buffer = outputBuffer, info = audioBufferInfo)
                        }
                    }
                    c.releaseOutputBuffer(index, false)
                    if (audioBufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                        return
                    }
                }
                index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    onEncoderFormat(isAudio = true, format = c.outputFormat)
                }
                index == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                    if (!endOfStream) return
                    if (System.nanoTime() > deadlineNs) {
                        Log.w(TAG, "drainAudio: EOS drain timed out")
                        return
                    }
                }
                else -> return
            }
        }
    }

    /**
     * 把紧凑 I420 数据按编码器实际要求的平面布局（rowStride / pixelStride）写入
     * 输入 Image。pixelStride == 2 时即 NV12/NV21 这类交错色度平面。
     */
    private fun writeToImage(image: android.media.Image, yuv: ByteArray) {
        val ySize = width * height
        val chromaW = width / 2
        val chromaH = height / 2
        val chromaSize = chromaW * chromaH
        // I420 源数据中三个平面的起始偏移：Y、U、V。
        val srcOffsets = intArrayOf(0, ySize, ySize + chromaSize)
        for (p in 0..2) {
            val plane = image.planes[p]
            val buf = plane.buffer
            val rowStride = plane.rowStride
            val pixelStride = plane.pixelStride
            val pw = if (p == 0) width else chromaW
            val ph = if (p == 0) height else chromaH
            var src = srcOffsets[p]
            if (pixelStride == 1) {
                for (row in 0 until ph) {
                    buf.position(row * rowStride)
                    buf.put(yuv, src, pw)
                    src += pw
                }
            } else {
                for (row in 0 until ph) {
                    val rowStart = row * rowStride
                    for (col in 0 until pw) {
                        buf.put(rowStart + col * pixelStride, yuv[src++])
                    }
                }
            }
        }
    }

    /**
     * Convert ARGB ImageBitmap pixels to I420 (YUV420 planar) via BT.601
     * coefficients. Writes into [yuvBuffer] as three contiguous planes:
     * Y (w*h), U (w*h/4), V (w*h/4).
     */
    private fun argbToYuv420(bitmap: ImageBitmap) {
        val pixels = pixelBuffer ?: return
        val yuv = yuvBuffer ?: return
        val w = width
        val h = height
        val ySize = w * h

        bitmap.readPixels(pixels, 0, 0, w, h, 0, w)

        // --- Y plane (full resolution) ---
        var yi = 0
        var pi = 0
        while (yi < ySize) {
            val argb = pixels[pi]
            val r = (argb shr 16) and 0xFF
            val g = (argb shr 8) and 0xFF
            val b = argb and 0xFF
            // BT.601: Y = 0.299R + 0.587G + 0.114B
            // Fixed-point: (77R + 150G + 29B) >> 8
            yuv[yi] = ((77 * r + 150 * g + 29 * b) shr 8).coerceIn(0, 255).toByte()
            yi++
            pi++
        }

        // --- U plane (half resolution, 2x2 average) ---
        var ui = ySize
        var row = 0
        while (row < h) {
            var col = 0
            while (col < w) {
                val base = row * w + col
                // Average 2x2 block.
                val p00 = pixels[base]
                val p01 = pixels[base + 1]
                val p10 = pixels[base + w]
                val p11 = pixels[base + w + 1]

                val r = (((p00 shr 16) and 0xFF) + ((p01 shr 16) and 0xFF) +
                         ((p10 shr 16) and 0xFF) + ((p11 shr 16) and 0xFF)) / 4
                val g = (((p00 shr 8) and 0xFF) + ((p01 shr 8) and 0xFF) +
                         ((p10 shr 8) and 0xFF) + ((p11 shr 8) and 0xFF)) / 4
                val b = ((p00 and 0xFF) + (p01 and 0xFF) +
                         (p10 and 0xFF) + (p11 and 0xFF)) / 4
                // BT.601: U = -0.169R - 0.331G + 0.500B + 128
                // Fixed-point: ((-43R - 85G + 128B) >> 8) + 128
                yuv[ui] = (((-43 * r - 85 * g + 128 * b) shr 8) + 128).coerceIn(0, 255).toByte()
                ui++
                col += 2
            }
            row += 2
        }

        // --- V plane (half resolution, 2x2 average) ---
        row = 0
        while (row < h) {
            var col = 0
            while (col < w) {
                val base = row * w + col
                val p00 = pixels[base]
                val p01 = pixels[base + 1]
                val p10 = pixels[base + w]
                val p11 = pixels[base + w + 1]

                val r = (((p00 shr 16) and 0xFF) + ((p01 shr 16) and 0xFF) +
                         ((p10 shr 16) and 0xFF) + ((p11 shr 16) and 0xFF)) / 4
                val g = (((p00 shr 8) and 0xFF) + ((p01 shr 8) and 0xFF) +
                         ((p10 shr 8) and 0xFF) + ((p11 shr 8) and 0xFF)) / 4
                val b = ((p00 and 0xFF) + (p01 and 0xFF) +
                         (p10 and 0xFF) + (p11 and 0xFF)) / 4
                // BT.601: V = 0.500R - 0.419G - 0.081B + 128
                // Fixed-point: ((128R - 107G - 21B) >> 8) + 128
                yuv[ui] = (((128 * r - 107 * g - 21 * b) shr 8) + 128).coerceIn(0, 255).toByte()
                ui++
                col += 2
            }
            row += 2
        }
    }

    private fun releaseInternal() {
        audioStopRequested = true
        // 正常路径 stop() 已 join 过音频线程；这里是异常路径的兜底（限时）。
        runCatching { audioThread?.join(500) }
        audioThread = null
        runCatching { audioRecord?.stop() }
        runCatching { audioRecord?.release() }
        audioRecord = null
        runCatching { audioCodec?.stop() }
        runCatching { audioCodec?.release() }
        audioCodec = null
        runCatching { videoCodec?.stop() }
        runCatching { videoCodec?.release() }
        videoCodec = null
        // muxer 置空放在 muxerLock 里：万一音频线程 join 超时还活着，
        // 它后续的 writeSample 会看到 null 直接返回，不摸已释放的 muxer。
        synchronized(muxerLock) {
            runCatching { muxer?.stop() }
            runCatching { muxer?.release() }
            muxer = null
            muxerStarted = false
            videoTrack = -1
            audioTrack = -1
            pendingVideo.clear()
            pendingAudio.clear()
            pendingBytes = 0
        }
        // pfd 必须在 muxer 收尾之后关（muxer 还要往里写 moov），且恰好关一次。
        runCatching { pfd?.close() }
        pfd = null
        displayName = null
        audioEnabled = false
        synchronized(ptsLock) {
            baseTimeNs = 0L
            pausedTotalNs = 0L
            pauseStartNs = 0L
        }
        lastVideoPtsUs = -1L
        lastAudioPtsUs = -1L
        yuvBuffer = null
        pixelBuffer = null
    }

    private fun bitRate(w: Int, h: Int, fps: Int): Int {
        val pixels = w * h
        // 基准 ~1.5 bit 系数按 30fps 标定；帧驱动 VFR 下有线监看可达 ~70fps，
        // 码率预算随帧率线性放大，避免高帧率被压成糊片。
        return (pixels * 1.5 * fps / 30.0).toInt().coerceIn(500_000, 20_000_000)
    }

    companion object {
        private const val TAG = "ViewfinderRecorder"
        private const val MIME_TYPE = "video/avc"
        private const val AUDIO_MIME_TYPE = "audio/mp4a-latm"
        private const val AUDIO_SAMPLE_RATE = 44_100
        private const val AUDIO_BIT_RATE = 128_000
        // 每次读 1024 个 16bit 单声道采样（~23ms），一块喂一次编码器。
        private const val AUDIO_CHUNK_BYTES = 2048
        private const val INPUT_TIMEOUT_US = 10_000L
        private const val DRAIN_TIMEOUT_US = 5_000L
        private const val EOS_TIMEOUT_US = 100_000L
        // muxer 启动前的暂存上限：正常竞态窗口只有几十毫秒，超限说明对端轨异常。
        private const val PENDING_CAP_BYTES = 16 * 1024 * 1024
        private val DATE_FMT = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US)

        /** 统一的录像文件命名；SAF 建档方（RemoteScreen）也用它，两条路径同名规则。 */
        fun newFileName(): String = "rec_${DATE_FMT.format(Date())}.mp4"
    }
}
