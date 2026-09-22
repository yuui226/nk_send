package com.ztransfer.ui.screen

import com.ztransfer.util.HistogramMode

import android.content.SharedPreferences
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.ztransfer.R

internal enum class RemoteTool(val id: String, val title: Int, val fixed: Boolean = false) {
    HD("hd", R.string.remote_tool_hd), FPS("fps", R.string.remote_tool_fps),
    AUDIO("audio", R.string.remote_tool_audio), HISTOGRAM("histogram", R.string.remote_tool_histogram),
    GRID("grid", R.string.remote_tool_grid), EXPOSURE("exposure", R.string.remote_tool_exposure),
    DESQUEEZE("desqueeze", R.string.remote_tool_desqueeze), LEVEL("level", R.string.remote_tool_level),
    RECORD("record", R.string.remote_tool_record), WHITE_BALANCE("white_balance", R.string.remote_tool_wb),
    FOCUS_AREA("focus_area", R.string.remote_tool_focus_area), WAVEFORM("waveform", R.string.remote_tool_waveform),
    LOCK("lock", R.string.remote_tool_lock),
    FULLSCREEN("fullscreen", R.string.remote_tool_fullscreen, true),
    ROTATE("rotate", R.string.remote_tool_rotate, true);

    fun availableIn(movie: Boolean) = this != AUDIO || movie

    companion object {
        val regular = entries.filterNot { it.fixed }
        fun ordered(ids: List<String>): List<RemoteTool> =
            (ids.mapNotNull { id -> regular.find { it.id == id } } + regular).distinct()
    }
}

internal enum class ExposureAssist { OFF, ZEBRA, FALSE_COLOR;
    fun next() = entries[(ordinal + 1) % entries.size]
}

internal enum class WaveformMode { OFF, LUMA, RGB;
    fun next() = entries[(ordinal + 1) % entries.size]
}

/** Writes on the user mutation, rather than waiting for page disposal or a composition effect. */
private class SavedToolState<T>(initial: T, private val save: (T) -> Unit) : MutableState<T> {
    private val state = mutableStateOf(initial)
    override var value: T
        get() = state.value
        set(value) { if (state.value != value) { save(value); state.value = value } }
    override fun component1(): T = value
    override fun component2(): (T) -> Unit = { value = it }
}

@Stable
internal class RemoteToolPreferences(private val prefs: SharedPreferences) {
    private fun bool(key: String, default: Boolean = false): MutableState<Boolean> = SavedToolState(prefs.getBoolean(key, default)) {
        prefs.edit().putBoolean(key, it).apply()
    }
    private inline fun <reified T : Enum<T>> enum(key: String, default: T): MutableState<T> = SavedToolState(
        enumValues<T>().find { it.name == prefs.getString(key, null) } ?: default
    ) { prefs.edit().putString(key, it.name).apply() }

    val fps = bool("remote_fps", true)
    val hd = bool("remote_hd")
    val histogram = enum("remote_histogram_mode", if (prefs.getBoolean("remote_histogram", false)) HistogramMode.LUMA else HistogramMode.OFF)
    val grid = enum("remote_grid", ViewfinderGrid.OFF)
    val exposure = enum("remote_exposure_assist", ExposureAssist.OFF)
    val level = bool("remote_level")
    val audio = bool("remote_audio_levels_visible", true)
    val desqueeze: MutableState<Float> = SavedToolState(
        prefs.getFloat("remote_desqueeze_multiplier", 1f).takeIf { it.isFinite() && it in 1f..2f } ?: 1f
    ) { prefs.edit().putFloat("remote_desqueeze_multiplier", it).apply() }
    val waveform = enum("remote_waveform_mode", if (prefs.getBoolean("remote_waveform", false)) WaveformMode.LUMA else WaveformMode.OFF)
    val locked = bool("remote_layout_locked")
    val lockedRotation: MutableState<Int> = SavedToolState(prefs.getInt("remote_locked_rotation", 0).coerceIn(0, 2)) {
        prefs.edit().putInt("remote_locked_rotation", it).apply()
    }
    private val photoLayout = RemoteToolLayout(prefs, false, ::disable)
    private val movieLayout = RemoteToolLayout(prefs, true, ::disable)
    fun layout(movie: Boolean) = if (movie) movieLayout else photoLayout

    private fun disable(tool: RemoteTool) {
        when (tool) {
            RemoteTool.HD -> hd.value = false
            RemoteTool.FPS -> fps.value = false
            RemoteTool.AUDIO -> audio.value = false
            RemoteTool.HISTOGRAM -> histogram.value = HistogramMode.OFF
            RemoteTool.GRID -> grid.value = ViewfinderGrid.OFF
            RemoteTool.EXPOSURE -> exposure.value = ExposureAssist.OFF
            RemoteTool.DESQUEEZE -> desqueeze.value = 1f
            RemoteTool.LEVEL -> level.value = false
            RemoteTool.WAVEFORM -> waveform.value = WaveformMode.OFF
            RemoteTool.LOCK -> locked.value = false
            else -> Unit // Actions and camera parameters are not reset by hiding their entry.
        }
    }
}

/** Photo and movie have independent layouts; screen rotation shares the active layout. */
@Stable
internal class RemoteToolLayout(
    private val prefs: SharedPreferences,
    movie: Boolean,
    private val onHide: (RemoteTool) -> Unit,
) {
    private val mode = if (movie) "movie" else "photo"
    private val orderKey = "remote_tool_order_$mode"
    private val hiddenKey = "remote_hidden_tools_$mode"
    private val lockPositionKey = "remote_lock_starts_second_row_$mode"
    private var lockAtSecondRowStart by mutableStateOf(prefs.getBoolean(lockPositionKey, true))
    val lockStartsSecondRow: Boolean get() = lockAtSecondRowStart && visible(RemoteTool.LOCK)
    val available = RemoteTool.regular.filter { it.availableIn(movie) }
    var order by mutableStateOf(RemoteTool.ordered(prefs.getString(orderKey, "").orEmpty().split(',')).filter { it in available })
        private set
    private var hidden by mutableStateOf(prefs.getStringSet(hiddenKey, emptySet()).orEmpty().toSet())
    fun visible(tool: RemoteTool) = tool.fixed || (tool in available && tool.id !in hidden)
    val shownTools: List<RemoteTool> get() = order.filter(::visible)
    val hiddenTools: List<RemoteTool> get() = order.filterNot(::visible)

    /** Only visible regular tools can move; hidden tools retain their own tail order. */
    fun move(tool: RemoteTool, toIndex: Int, displayedOrder: List<RemoteTool> = shownTools) {
        if (tool.fixed || !visible(tool)) return
        val original = shownTools
        val target = original.getOrNull(toIndex)
        val detachLock = lockAtSecondRowStart && (tool == RemoteTool.LOCK || target == RemoteTool.LOCK)
        val shown = (if (detachLock) displayedOrder else original).toMutableList()
        val destination = if (detachLock && target != null) shown.indexOf(target) else toIndex
        if (!shown.remove(tool)) return
        if (detachLock) lockAtSecondRowStart = false
        shown.add(destination.coerceIn(0, shown.size), tool)
        order = shown + hiddenTools
        prefs.edit().putString(orderKey, order.joinToString(",") { it.id })
            .putBoolean(lockPositionKey, lockAtSecondRowStart).apply()
    }
    fun setVisible(tool: RemoteTool, visible: Boolean) {
        if (tool.fixed || tool !in available) return
        if (!visible) onHide(tool)
        if (this.visible(tool) == visible) return
        if (tool == RemoteTool.LOCK) lockAtSecondRowStart = false
        val others = order.filterNot { it == tool }
        hidden = if (visible) hidden - tool.id else hidden + tool.id
        order = if (visible) others.filter(this::visible) + tool + others.filterNot(this::visible)
            else others.filter(this::visible) + others.filterNot(this::visible) + tool
        prefs.edit().putStringSet(hiddenKey, hidden)
            .putBoolean(lockPositionKey, lockAtSecondRowStart)
            .putString(orderKey, order.joinToString(",") { it.id }).apply()
    }
}
