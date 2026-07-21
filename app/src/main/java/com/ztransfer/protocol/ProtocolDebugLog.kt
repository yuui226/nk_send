package com.ztransfer.protocol

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** 真机离线调试用的内存环形日志；不写文件、不记录照片内容。 */
object ProtocolDebugLog {
    private const val MAX_LINES = 500
    private val lock = Any()
    private val formatter = SimpleDateFormat("HH:mm:ss.SSS", Locale.US)
    private val _text = MutableStateFlow("")
    val text: StateFlow<String> = _text.asStateFlow()

    fun add(message: String) {
        synchronized(lock) {
            val line = "${formatter.format(Date())} $message"
            val lines = if (_text.value.isEmpty()) mutableListOf() else _text.value.lines().toMutableList()
            lines += line
            if (lines.size > MAX_LINES) lines.subList(0, lines.size - MAX_LINES).clear()
            _text.value = lines.joinToString("\n")
        }
    }

    fun clear() = synchronized(lock) { _text.value = "" }
}
