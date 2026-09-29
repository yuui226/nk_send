package com.ztransfer.diagnostics

import android.os.SystemClock
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import java.time.Instant
import java.util.concurrent.atomic.AtomicLong

/** Debug-only bounded performance summaries. No EXIF, URI or protocol transcript. */
object PhotoGenerationProbe {
    const val enabled = true
    const val NO_SESSION = -1L
    private const val MAX_SESSIONS = 6
    private data class Session(
        val id: Long, val source: String, val config: String, val started: Long,
        val stages: LinkedHashMap<String, Long> = linkedMapOf(),
        var outcome: String = "running", var total: Long? = null,
        var heap: Long = 0, var pixels: Long? = null, var kernel: String? = null, var grid: String? = null,
    )
    private val ids = AtomicLong()
    private val lock = Any()
    private val sessions = linkedMapOf<Long, Session>()
    private val _version = MutableStateFlow(0)
    val version: StateFlow<Int> = _version.asStateFlow()
    private val pixelPattern = Regex("(?:^| )pixels=(\\d+)")
    private val labels = linkedMapOf(
        "worker_wait" to "入场等待", "metadata_prepare" to "资料就绪",
        "metadata_fetch" to "补头含等待", "destination_prepare" to "目录",
        "source_materialize" to "源复制", "region_decoder_open" to "解码器",
        "full_decode" to "整图解码", "region_decode" to "分区解码",
        "filter_lookup_prepare" to "颜色准备", "filter_pixels" to "颜色计算",
        "frame_setup" to "画布", "frame_compose" to "合成",
        "frame_decoration" to "边框", "region_orient_draw" to "区域绘制",
        "backdrop_preview_decode" to "背景解码", "backdrop_draw" to "背景",
        "photo_elevation" to "照片阴影", "render_total" to "渲染总计",
        "output_create" to "建文件", "jpeg_encode_write" to "编码写入",
        "exif_rewrite" to "写EXIF", "output_finalize" to "发布",
        "save_total" to "保存总计",
    )

    fun begin(sourceName: String, configuration: String): Long {
        val id = ids.incrementAndGet()
        synchronized(lock) {
            sessions[id] = Session(id, compact(sourceName, 48), compact(configuration, 140), SystemClock.elapsedRealtime())
            while (sessions.size > MAX_SESSIONS) sessions.remove(sessions.keys.first())
        }
        bump()
        return id
    }

    fun stage(sessionId: Long, name: String, durationMs: Long, detail: String = "") {
        if (name !in labels) return
        synchronized(lock) {
            val session = sessions[sessionId] ?: return
            val time = durationMs.coerceAtLeast(0)
            // These are offsets from admission; retries/defer must not add their overlaps.
            session.stages[name] = if (name == "worker_wait" || name == "metadata_prepare") time
                else (session.stages[name] ?: 0L) + time
            val runtime = Runtime.getRuntime()
            session.heap = maxOf(session.heap, (runtime.totalMemory() - runtime.freeMemory()) / (1024 * 1024))
            if (name == "filter_lookup_prepare") session.kernel =
                Regex("(?:^| )kernel=(\\S+)").find(detail)?.groupValues?.get(1)
            if (name == "filter_lookup_prepare") session.grid =
                Regex("(?:^| )grid=(\\d+)").find(detail)?.groupValues?.get(1)
            if (name == "filter_pixels") session.pixels = pixelPattern.find(detail)?.groupValues?.get(1)?.toLongOrNull()
        }
        bump()
    }

    fun finish(sessionId: Long, outcome: String, totalMs: Long) {
        synchronized(lock) {
            val session = sessions[sessionId] ?: return
            session.outcome = compact(outcome, 60)
            session.total = totalMs.coerceAtLeast(0)
        }
        bump()
    }

    // Preserve callers without allocating/storing verbose notes or triggering UI refreshes.
    @Suppress("UNUSED_PARAMETER") fun note(category: String, message: String) = Unit
    @Suppress("UNUSED_PARAMETER") fun frameNote(sessionId: Long, category: String, message: String) = Unit

    fun clear() { synchronized(lock) { sessions.clear() }; bump() }

    fun displayLines(): List<String> = report().lines()

    fun report(): String = synchronized(lock) {
        val now = SystemClock.elapsedRealtime()
        val header = "ZTransfer 性能 v3 ${Instant.now()}\n单位ms；最新在前，最多6张。总计含子项，勿相加。入场等待含资料等待；资料就绪为入队后偏移；补头含通道等待。堆为Java采样最大值，非峰值。\n"
        boundedTimingReport(header, sessions.values.toList().asReversed().map { session ->
            buildString {
                appendLine("#${session.id} ${session.source} ${session.outcome} 总=${session.total ?: (now - session.started)} 堆=${session.heap}MiB")
                appendLine(session.config)
                session.kernel?.let { append("执行=$it ") }
                session.grid?.takeUnless { it == "0" }?.let { append("LUT格=$it ") }
                session.pixels?.let { append("像素=$it ") }
                append(session.stages.entries.joinToString(" ") { (name, ms) -> "${labels.getValue(name)}=$ms" })
                if (session.stages.isEmpty()) append("等待记录")
            }
        })
    }

    private fun compact(text: String, limit: Int) = text.replace(Regex("\\s+"), " ").take(limit)
    private fun bump() { _version.update { it + 1 } }
}

/** Keep whole photos, never cut the slow stage off the end of a record. */
internal fun boundedTimingReport(header: String, newestFirst: List<String>): String {
    val suffix = "\n更早记录已省略；建议清空后测2–3张。"
    val result = StringBuilder(header)
    if (newestFirst.isEmpty()) return result.append("暂无记录：生成一张启用滤镜/LUT/边框的照片。").toString()
    for (record in newestFirst) {
        val next = "$result\n$record\n"
        if ((next + suffix).length > 2800 || (next + suffix).toByteArray(Charsets.UTF_8).size > 6000) {
            result.append(suffix)
            break
        }
        result.append('\n').append(record).append('\n')
    }
    return result.toString()
}
