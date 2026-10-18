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
    WHITE_BALANCE("white_balance", R.string.remote_tool_wb),
    FOCUS_AREA("focus_area", R.string.remote_tool_focus_area), WAVEFORM("waveform", R.string.remote_tool_waveform),
    FOCUS_MODE("focus_mode", R.string.remote_tool_focus_mode),
    FOCUS_FRAME("focus_frame", R.string.remote_tool_focus_frame),
    LUT("lut", R.string.remote_tool_lut),
    PICTURE_CONTROL("picture_control", R.string.remote_tool_picture_control),
    METER("meter", R.string.remote_tool_meter),
    LOCK("lock", R.string.remote_tool_lock, true),
    COMPUTER_CONTROL("computer_control", R.string.remote_tool_computer_control),
    ROTATE("rotate", R.string.remote_tool_rotate, true);

    fun availableIn(movie: Boolean) = this != AUDIO || movie

    companion object {
        val pinned = listOf(LOCK, ROTATE)
        val regular = entries.filterNot { it.fixed }
        // Ignore retired/unknown IDs while preserving the user's remaining order.
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
    init {
        // One-time introduction: also reset preferences saved by pre-release test builds.
        // Later launches respect the user's own switch and visibility choices.
        if (!prefs.getBoolean("remote_focus_frame_introduced_v1", false)) {
            val edit = prefs.edit().putBoolean("remote_focus_frame", true)
                .putBoolean("remote_focus_frame_introduced_v1", true)
            for (mode in listOf("photo", "movie")) {
                val key = "remote_hidden_tools_$mode"
                edit.putStringSet(key, prefs.getStringSet(key, emptySet()).orEmpty() - RemoteTool.FOCUS_FRAME.id)
            }
            edit.apply()
        }
    }

    private fun bool(key: String, default: Boolean = false): MutableState<Boolean> = SavedToolState(prefs.getBoolean(key, default)) {
        prefs.edit().putBoolean(key, it).apply()
    }
    private inline fun <reified T : Enum<T>> enum(key: String, default: T): MutableState<T> = SavedToolState(
        enumValues<T>().find { it.name == prefs.getString(key, null) } ?: default
    ) { prefs.edit().putString(key, it.name).apply() }

    val disp = enum("remote_disp_mode", MonitorDispMode.CAMERA)
    val fps = bool("remote_fps", true)
    val hd = bool("remote_hd")
    val computerControl = bool("remote_computer_control")
    val histogram = enum("remote_histogram_mode", if (prefs.getBoolean("remote_histogram", false)) HistogramMode.LUMA else HistogramMode.OFF)
    val grid = enum("remote_grid", ViewfinderGrid.OFF)
    val exposure = enum("remote_exposure_assist", ExposureAssist.OFF)
    val level = bool("remote_level")
    val focusFrame = bool("remote_focus_frame", true)
    val meter = bool("remote_exposure_meter")
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
            RemoteTool.COMPUTER_CONTROL -> computerControl.value = false
            RemoteTool.FPS -> fps.value = false
            RemoteTool.AUDIO -> audio.value = false
            RemoteTool.HISTOGRAM -> histogram.value = HistogramMode.OFF
            RemoteTool.GRID -> grid.value = ViewfinderGrid.OFF
            RemoteTool.EXPOSURE -> exposure.value = ExposureAssist.OFF
            RemoteTool.DESQUEEZE -> desqueeze.value = 1f
            RemoteTool.LEVEL -> level.value = false
            RemoteTool.FOCUS_FRAME -> focusFrame.value = false
            RemoteTool.METER -> meter.value = false
            RemoteTool.WAVEFORM -> waveform.value = WaveformMode.OFF
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
    private val presetPlacementKey = "remote_picture_control_placement_v1_$mode"
    val available = RemoteTool.regular.filter { it.availableIn(movie) }
    var order by mutableStateOf(RemoteTool.ordered(prefs.getString(orderKey, "").orEmpty().split(',')).filter { it in available })
        private set
    // Fixed controls and retired tools ignore saved visibility entries from older versions.
    private var hidden by mutableStateOf(prefs.getStringSet(hiddenKey, emptySet()).orEmpty()
        .filter { id -> available.any { it.id == id } }.toSet())

    init {
        if (!prefs.getBoolean(presetPlacementKey, false)) {
            // Introduce Picture Control once, including on fresh installs. Persist all three
            // values together so later launches respect the user's own moves and visibility.
            val preset = RemoteTool.PICTURE_CONTROL
            hidden = hidden - preset.id
            val others = order.filterNot { it == preset }
            val preceding = others.withIndex().filter { visible(it.value) }.take(5)
            val insertion = preceding.lastOrNull()?.let { it.index + 1 } ?: 0
            order = others.toMutableList().apply { add(insertion, preset) }
            prefs.edit()
                .putString(orderKey, order.joinToString(",") { it.id })
                .putStringSet(hiddenKey, hidden)
                .putBoolean(presetPlacementKey, true)
                .apply()
        }
    }

    fun visible(tool: RemoteTool) = tool.fixed || (tool in available && tool.id !in hidden)
    val shownTools: List<RemoteTool> get() = order.filter(::visible)
    val hiddenTools: List<RemoteTool> get() = order.filterNot(::visible)

    /** Only visible regular tools can move; hidden tools retain their own tail order. */
    fun move(tool: RemoteTool, toIndex: Int) {
        if (tool.fixed || !visible(tool)) return
        val shown = shownTools.toMutableList()
        if (!shown.remove(tool)) return
        shown.add(toIndex.coerceIn(0, shown.size), tool)
        order = shown + hiddenTools
        prefs.edit().putString(orderKey, order.joinToString(",") { it.id }).apply()
    }
    fun setVisible(tool: RemoteTool, visible: Boolean) {
        if (tool.fixed || tool !in available) return
        if (!visible) onHide(tool)
        if (this.visible(tool) == visible) return
        val others = order.filterNot { it == tool }
        hidden = if (visible) hidden - tool.id else hidden + tool.id
        order = if (visible) others.filter(this::visible) + tool + others.filterNot(this::visible)
            else others.filter(this::visible) + others.filterNot(this::visible) + tool
        prefs.edit().putStringSet(hiddenKey, hidden)
            .putString(orderKey, order.joinToString(",") { it.id }).apply()
    }
}
