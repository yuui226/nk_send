package com.ztransfer.ui.screen

import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ztransfer.R
import com.ztransfer.protocol.*
import com.ztransfer.ui.theme.AppTheme
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay

internal val MonitorDispInformationInset = 32.dp

internal enum class MonitorDispMode {
    CAMERA, EXPOSURE, CLEAN;
    fun next() = entries[(ordinal + 1) % entries.size]
}

/** Optional DISP properties are only polled while their information view is active. */
@Composable
internal fun rememberMonitorDetails(
    camera: NikonCamera?,
    movie: Boolean,
    enabled: Boolean,
    pollingAllowed: Boolean,
): Map<RemoteCameraTool, String> {
    val context = LocalContext.current
    val canPoll by rememberUpdatedState(pollingAllowed)
    var details by remember(camera, movie) { mutableStateOf(emptyMap<RemoteCameraTool, String>()) }
    LaunchedEffect(camera, movie, enabled, context) {
        details = emptyMap()
        if (!enabled || camera == null) return@LaunchedEffect
        // A capture temporarily pauses I/O without discarding descriptors or visible labels.
        suspend fun awaitPolling() {
            while (!canPoll) delay(100)
        }
        // Resolve supported properties once, then only read their scalar values.
        // Unsupported options are omitted rather than probed on every refresh.
        val tools = listOf(RemoteCameraTool.WHITE_BALANCE)
        val properties = tools.mapNotNull { tool ->
            try {
                awaitPolling()
                camera.rcGetCameraTool(tool, movie)?.let { tool to it }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { null }
        }
        var initial = true
        while (true) {
            details = properties.mapNotNull { (tool, descriptor) ->
                try {
                    awaitPolling()
                    (if (initial) descriptor else camera.rcRefreshParam(descriptor))?.let { param ->
                        cameraToolLabelResource(tool, param.prop, param.current)?.let { tool to context.getString(it) }
                    }
                } catch (cancelled: CancellationException) { throw cancelled }
                catch (_: Exception) { null }
            }.toMap()
            initial = false
            if (properties.isEmpty()) break
            delay(2_000)
        }
    }
    return if (enabled) details else emptyMap()
}

/** Compact DISP mode summary; exposure values remain in the adjustment wheels. */
@Composable
internal fun MonitorDispSummary(
    mode: MonitorDispMode,
    information: List<String>,
    connected: Boolean,
    modifier: Modifier = Modifier,
) {
    val colors = AppTheme.colors
        Text(
            modifier = modifier,
            text = if (!connected) stringResource(R.string.connection_lost)
                else if (mode != MonitorDispMode.EXPOSURE) "" else information.joinToString("   "),
            color = if (connected) androidx.compose.ui.graphics.Color.White else colors.statusError,
            fontSize = 11.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
            style = androidx.compose.ui.text.TextStyle(shadow = androidx.compose.ui.graphics.Shadow(
                androidx.compose.ui.graphics.Color.Black, blurRadius = 4f)),
        )
}

@Composable
internal fun rememberMonitorStorage(camera: NikonCamera?, storageIds: List<Int>, enabled: Boolean,
    pollingAllowed: Boolean): List<Pair<Int, Long>> {
    var values by remember(camera, storageIds) { mutableStateOf(emptyList<Pair<Int, Long>>()) }
    val canPoll by rememberUpdatedState(pollingAllowed)
    LaunchedEffect(camera, storageIds, enabled) {
        values = emptyList()
        if (!enabled || camera == null) return@LaunchedEffect
        // Use actual IDs from discovery; never sum an aggregate ID with its physical cards.
        val ids = storageIds.filter { it != 0 && it != -1 }.distinct()
        val supported = ids.toMutableList()
        while (supported.isNotEmpty()) {
            val next = mutableListOf<Pair<Int, Long>>()
            for (id in supported.toList()) {
                while (!canPoll) delay(250)
                try {
                    val result = camera.monitorFreeBytes(id) { canPoll }
                    if (result.unsupported) {
                        supported.clear()
                        break
                    }
                    result.freeBytes?.let { next += (ids.indexOf(id) + 1) to it }
                } catch (cancelled: CancellationException) { throw cancelled }
                catch (_: Exception) { /* Hide stale data; retry on the next slow refresh. */ }
            }
            values = next
            delay(30_000)
        }
    }
    return if (enabled) values else emptyList()
}

internal fun monitorRemainingTimeLabel(seconds: Long): String =
    if (seconds >= 3600) String.format(java.util.Locale.ROOT, "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    else String.format(java.util.Locale.ROOT, "%02d:%02d", seconds / 60, seconds % 60)

/** Camera-style readout; no background panel over the live image. */
@Composable
internal fun CameraMonitorDisp(cells: List<Pair<String, String>>, storage: List<Pair<Int, Long>>,
    movie: Boolean, battery: Int?, recording: Boolean, modifier: Modifier = Modifier,
    storageSlotCount: Int = storage.size,
    remainingVideoMs: () -> Long? = { null }) {
    val videoSource by rememberUpdatedState(remainingVideoMs)
    val videoSeconds by remember(movie) { derivedStateOf { if (movie) videoSource()?.div(1000) else null } }
    val remaining = if (movie) videoSeconds?.let { stringResource(R.string.monitor_disp_remaining_video, monitorRemainingTimeLabel(it)) }
        else null
    val shadow = androidx.compose.ui.text.TextStyle(shadow = androidx.compose.ui.graphics.Shadow(
        androidx.compose.ui.graphics.Color.Black.copy(alpha = .85f), blurRadius = 4f))
    val white = androidx.compose.ui.graphics.Color.White
    Box(modifier.padding(horizontal = 12.dp, vertical = MonitorInfoTopInset)) {
        val topItems = storage.map { (number, free) ->
                val capacity = String.format(java.util.Locale.getDefault(), "%.1f GB", free / 1_000_000_000.0)
                if (storageSlotCount <= 1) capacity else stringResource(R.string.monitor_disp_card, number, capacity)
            } + listOfNotNull(battery?.let { "$it%" })
        Column(Modifier.align(Alignment.TopStart).fillMaxWidth().padding(end = 100.dp),
            verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(topItems.joinToString("   ·   "),
                color = white, fontSize = 12.sp, style = shadow, maxLines = 1, overflow = TextOverflow.Ellipsis)
            remaining?.let { Text(it, color = white.copy(alpha = .85f), fontSize = 11.sp,
                style = shadow, maxLines = 1, overflow = TextOverflow.Ellipsis) }
        }
        if (movie && !recording) Text("STBY", Modifier.align(Alignment.TopEnd),
            color = white.copy(alpha = .8f), fontSize = 11.sp, style = shadow)
        Row(
            Modifier.align(Alignment.BottomStart).widthIn(max = 400.dp),
            horizontalArrangement = Arrangement.spacedBy(16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            cells.forEach { (label, value) ->
                Row(Modifier.weight(1f, fill = false),
                    horizontalArrangement = Arrangement.spacedBy(5.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Text(label, color = white.copy(alpha = .65f), fontSize = 9.sp,
                        maxLines = 1, softWrap = false, style = shadow,
                        modifier = Modifier.alignByBaseline())
                    Text(value, color = white, fontSize = 12.sp, fontWeight = FontWeight.Medium,
                        maxLines = 1, overflow = TextOverflow.Ellipsis, style = shadow,
                        modifier = Modifier.weight(1f, fill = false).alignByBaseline())
                }
            }
        }
    }
}
