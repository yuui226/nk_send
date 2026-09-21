package com.ztransfer.ui.screen

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

    companion object {
        val regular = entries.filterNot { it.fixed }
        fun ordered(ids: List<String>): List<RemoteTool> =
            (ids.mapNotNull { id -> regular.find { it.id == id } } + regular).distinct()
    }
}

internal enum class ExposureAssist { OFF, ZEBRA, FALSE_COLOR;
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
    val histogram = bool("remote_histogram")
    val grid = enum("remote_grid", ViewfinderGrid.OFF)
    val exposure = enum("remote_exposure_assist", ExposureAssist.OFF)
    val level = bool("remote_level")
    val audio = bool("remote_audio_levels_visible", true)
    val desqueeze: MutableState<Float> = SavedToolState(
        prefs.getFloat("remote_desqueeze_multiplier", 1f).takeIf { it.isFinite() && it in 1f..2f } ?: 1f
    ) { prefs.edit().putFloat("remote_desqueeze_multiplier", it).apply() }
    val waveform = bool("remote_waveform")
    val locked = bool("remote_layout_locked")
    val lockedRotation: MutableState<Int> = SavedToolState(prefs.getInt("remote_locked_rotation", 0).coerceIn(0, 2)) {
        prefs.edit().putInt("remote_locked_rotation", it).apply()
    }
    var order by mutableStateOf(RemoteTool.ordered(prefs.getString("remote_tool_order", "").orEmpty().split(',')))
        private set
    private var hidden by mutableStateOf(prefs.getStringSet("remote_hidden_tools", emptySet()).orEmpty().toSet())
    fun visible(tool: RemoteTool) = tool.id !in hidden
    fun move(tool: RemoteTool, toIndex: Int) {
        if (tool.fixed) return
        val updated = order.toMutableList()
        if (!updated.remove(tool)) return
        updated.add(toIndex.coerceIn(0, updated.size), tool)
        order = updated
        prefs.edit().putString("remote_tool_order", updated.joinToString(",") { it.id }).apply()
    }
    fun setVisible(tool: RemoteTool, visible: Boolean) {
        if (!visible) disable(tool)
        hidden = if (visible) hidden - tool.id else hidden + tool.id
        prefs.edit().putStringSet("remote_hidden_tools", hidden).apply()
    }
    private fun disable(tool: RemoteTool) {
        when (tool) {
            RemoteTool.HD -> hd.value = false
            RemoteTool.FPS -> fps.value = false
            RemoteTool.AUDIO -> audio.value = false
            RemoteTool.HISTOGRAM -> histogram.value = false
            RemoteTool.GRID -> grid.value = ViewfinderGrid.OFF
            RemoteTool.EXPOSURE -> exposure.value = ExposureAssist.OFF
            RemoteTool.DESQUEEZE -> desqueeze.value = 1f
            RemoteTool.LEVEL -> level.value = false
            RemoteTool.WAVEFORM -> waveform.value = false
            RemoteTool.LOCK -> locked.value = false
            else -> Unit // Actions and camera parameters are not reset by hiding their entry.
        }
    }
    init { RemoteTool.entries.filterNot(::visible).forEach(::disable) }
}
