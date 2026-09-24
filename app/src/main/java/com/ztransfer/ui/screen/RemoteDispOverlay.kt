package com.ztransfer.ui.screen

import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.material3.LocalContentColor
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

internal enum class MonitorDispMode {
    CLEAN, EXPOSURE, FULL;
    fun next() = entries[(ordinal + 1) % entries.size]
}

/** Only the full information view requests these optional properties; never invent labels. */
@Composable
internal fun rememberMonitorDetails(
    camera: NikonCamera?,
    movie: Boolean,
    enabled: Boolean,
    pollingAllowed: Boolean,
): List<String> {
    val context = LocalContext.current
    val canPoll by rememberUpdatedState(pollingAllowed)
    var details by remember(camera, movie) { mutableStateOf(emptyList<String>()) }
    LaunchedEffect(camera, movie, enabled, context) {
        details = emptyList()
        if (!enabled || camera == null) return@LaunchedEffect
        // A capture temporarily pauses I/O without discarding descriptors or visible labels.
        suspend fun awaitPolling() {
            while (!canPoll) delay(100)
        }
        // Resolve supported properties once, then only read their scalar values.
        // Unsupported options are omitted rather than probed on every refresh.
        val properties = RemoteCameraTool.entries.mapNotNull { tool ->
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
                        cameraToolLabelResource(tool, param.prop, param.current)?.let(context::getString)
                    }
                } catch (cancelled: CancellationException) { throw cancelled }
                catch (_: Exception) { null }
            }
            initial = false
            if (properties.isEmpty()) break
            delay(2_000)
        }
    }
    return if (enabled) details else emptyList()
}

/** Compact exposure overlay takes no space away from the live image. */
@Composable
internal fun ImmersiveMonitorFooter(
    mode: MonitorDispMode,
    exposure: List<String>,
    connected: Boolean,
    modifier: Modifier = Modifier,
) {
    val colors = AppTheme.colors
    Crossfade(mode, animationSpec = tween(180), label = "monitorDisp", modifier = modifier) { selected ->
        Text(
            text = if (!connected) stringResource(R.string.connection_lost)
                else if (selected == MonitorDispMode.CLEAN) "" else exposure.joinToString("   "),
            color = if (connected) androidx.compose.ui.graphics.Color.White else colors.statusError,
            fontSize = 11.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
            style = androidx.compose.ui.text.TextStyle(shadow = androidx.compose.ui.graphics.Shadow(
                androidx.compose.ui.graphics.Color.Black, blurRadius = 4f)),
        )
    }
}

/** A single side rail keeps all immersive actions outside the image. */
@Composable
internal fun ImmersiveMonitorControls(
    onExit: () -> Unit,
    onCycle: () -> Unit,
    modifier: Modifier = Modifier,
    shutter: @Composable () -> Unit,
) {
    val colors = AppTheme.colors
    Column(modifier, horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(18.dp, Alignment.CenterVertically)) {
        GlassButton(
            onClick = onExit, shape = RoundedCornerShape(22.dp), showSheen = false,
            contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp),
            modifier = Modifier.height(36.dp),
        ) {
            val exitLabel = stringResource(R.string.cd_remote_fullscreen_exit)
            CompositionLocalProvider(LocalContentColor provides colors.onBackground) {
                FullscreenMark(Modifier.size(20.dp).semantics { contentDescription = exitLabel }, exiting = true)
            }
        }
        shutter()
        GlassButton(
            onClick = onCycle,
            contentPadding = PaddingValues(horizontal = 9.dp, vertical = 6.dp),
            modifier = Modifier.height(36.dp),
        ) {
            Text("DISP", color = colors.onBackground, fontSize = 10.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}

@Composable
internal fun ImmersiveMonitorDetails(details: List<String>, battery: Int?, modifier: Modifier = Modifier) {
    val text = (details + listOfNotNull(battery?.let { "$it%" })).joinToString("   ·   ")
    Text(text, modifier, color = androidx.compose.ui.graphics.Color.White,
        fontSize = 10.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
        style = androidx.compose.ui.text.TextStyle(shadow = androidx.compose.ui.graphics.Shadow(
            androidx.compose.ui.graphics.Color.Black, blurRadius = 4f)))
}
