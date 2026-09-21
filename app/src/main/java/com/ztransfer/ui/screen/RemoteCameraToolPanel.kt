package com.ztransfer.ui.screen

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.ztransfer.R
import com.ztransfer.protocol.*
import com.ztransfer.ui.theme.AppTheme
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/** Labels only for documented codes; never invent a name for a model-specific numeric value. */
internal fun cameraToolLabelResource(tool: RemoteCameraTool, prop: Int, value: Long): Int? = when (tool) {
    RemoteCameraTool.WHITE_BALANCE -> when (value) {
        1L -> R.string.remote_wb_manual
        2L -> R.string.remote_wb_auto
        3L -> R.string.remote_wb_one_push
        4L -> R.string.remote_wb_daylight
        5L -> R.string.remote_wb_fluorescent
        6L -> R.string.remote_wb_incandescent
        7L, 0x8015L -> R.string.remote_wb_flash
        0x8010L -> R.string.remote_wb_cloudy
        0x8011L -> R.string.remote_wb_shade
        0x8012L -> R.string.remote_wb_kelvin
        0x8013L -> R.string.remote_wb_preset
        0x8014L -> R.string.remote_wb_off
        0x8016L -> R.string.remote_wb_natural
        else -> null
    }
    RemoteCameraTool.FOCUS_AREA -> if (prop == 0x501C) when (value) {
        2L -> R.string.remote_af_dynamic
        0x8010L -> R.string.remote_af_single
        0x8011L -> R.string.remote_af_auto
        0x8012L -> R.string.remote_af_tracking
        0x8015L -> R.string.remote_af_group
        0x8017L -> R.string.remote_af_pinpoint
        0x8018L -> R.string.remote_af_wide_s
        0x8019L -> R.string.remote_af_wide_l
        0x801EL -> R.string.remote_af_wide_c1
        0x801FL -> R.string.remote_af_wide_c2
        else -> null
    } else null
}

@Composable
internal fun RemoteCameraToolPanel(
    camera: NikonCamera?, movie: Boolean, tool: RemoteCameraTool, canWrite: Boolean,
    isCurrentCamera: () -> Boolean,
    beforeWrite: suspend () -> Boolean,
    onApplied: suspend () -> Unit,
    log: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    val colors = AppTheme.colors
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val access = remember { Mutex() }
    var param by remember(camera, movie, tool) { mutableStateOf<RcParam?>(null) }
    var loading by remember(camera, movie, tool) { mutableStateOf(true) }
    var busy by remember { mutableStateOf(false) }
    var error by remember(camera, movie, tool) { mutableStateOf<String?>(null) }
    val currentCanWrite by rememberUpdatedState(canWrite)
    val currentCameraCheck by rememberUpdatedState(isCurrentCamera)
    val latestMovie by rememberUpdatedState(movie)
    val title = stringResource(if (tool == RemoteCameraTool.WHITE_BALANCE) R.string.remote_tool_wb else R.string.remote_tool_focus_area)
    fun label(p: RcParam, value: Long): String = cameraToolLabelResource(tool, p.prop, value)?.let(context::getString)
        ?: context.getString(R.string.remote_camera_option, value.toString())
    LaunchedEffect(camera, movie, tool) {
        if (camera == null) { loading = false; return@LaunchedEffect }
        while (true) {
            if (!busy && currentCameraCheck()) {
                try {
                    access.withLock {
                        if (!busy && currentCameraCheck()) {
                            param = camera.rcGetCameraTool(tool, movie, if (loading) log else { _ -> })
                        }
                    }
                } catch (cancelled: CancellationException) { throw cancelled }
                catch (e: Exception) {
                    param = null
                    log("!! camera tool read ${tool.name}: ${e.javaClass.simpleName}")
                }
                loading = false
            }
            delay(1_200)
        }
    }
    BackHandler { if (!busy) onDismiss() }
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Box(Modifier.fillMaxSize().background(colors.scrim).clickable(
            interactionSource = remember { MutableInteractionSource() }, indication = null,
        ) { if (!busy) onDismiss() })
        Surface(Modifier.padding(24.dp).widthIn(max = 340.dp).fillMaxWidth().heightIn(max = 440.dp),
            color = colors.glassSurfaceHeavy, shape = RoundedCornerShape(22.dp), shadowElevation = 6.dp) {
            Column(Modifier.padding(vertical = 10.dp)) {
                Row(Modifier.fillMaxWidth().padding(start = 20.dp, end = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(title, color = colors.onBackground, style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                    IconButton(onClick = onDismiss, enabled = !busy) { Icon(Icons.Default.Close, stringResource(R.string.cd_close), tint = colors.onSurfaceVariant) }
                }
                if (loading || busy) LinearProgressIndicator(Modifier.fillMaxWidth().padding(horizontal = 20.dp), color = colors.accentBlue)
                val p = param
                if (!loading && (p == null || !p.writable || p.values.isEmpty())) Text(
                    stringResource(R.string.remote_camera_tool_unavailable), color = colors.onSurfaceVariant,
                    style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(horizontal = 20.dp, vertical = 12.dp))
                error?.let { Text(it, color = colors.accentOrange, style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(horizontal = 20.dp, vertical = 8.dp)) }
                if (p != null) LazyColumn(Modifier.weight(1f, fill = false)) {
                    items((p.values + p.current).distinct(), key = { it }) { value ->
                        val selected = value == p.current
                        Row(Modifier.fillMaxWidth().background(if (selected) colors.accentBlue.copy(alpha = 0.08f) else androidx.compose.ui.graphics.Color.Transparent)
                            .clickable(enabled = !busy && canWrite && p.writable && value in p.values && !selected) {
                                val cam = camera ?: return@clickable
                                busy = true
                                error = null
                                scope.launch {
                                    var acquired = false
                                    try {
                                        access.lock()
                                        acquired = true
                                        if (!currentCameraCheck() || !currentCanWrite || latestMovie != movie) {
                                            error = context.getString(R.string.remote_camera_tool_changed)
                                            return@launch
                                        }
                                        // Re-read descriptors before writing; a physical selector may have changed.
                                        val liveMovie = cam.rcGetMovieMode()
                                        if (liveMovie != null && liveMovie != movie) {
                                            error = context.getString(R.string.remote_camera_tool_changed)
                                            return@launch
                                        }
                                        val fresh = cam.rcGetCameraTool(tool, movie, log)
                                        if (fresh == null || fresh.prop != p.prop || !fresh.writable || value !in fresh.values) {
                                            param = fresh
                                            error = context.getString(R.string.remote_camera_tool_changed)
                                            return@launch
                                        }
                                        if (!currentCameraCheck() || !currentCanWrite || latestMovie != movie) {
                                            error = context.getString(R.string.remote_camera_tool_changed)
                                            return@launch
                                        }
                                        if (!beforeWrite()) {
                                            error = context.getString(R.string.remote_camera_tool_failed)
                                            return@launch
                                        }
                                        withContext(NonCancellable) {
                                            val result = cam.rcSetValueVerified(fresh, value)
                                            log("camera tool write ${tool.name} prop=0x%04X target=%d confirmed=%s response=0x%04X".format(fresh.prop, value, result.confirmed, result.responseCode))
                                            if (currentCameraCheck() && latestMovie == movie) {
                                                param = result.actual ?: cam.rcGetCameraTool(tool, movie)
                                                if (result.confirmed) onApplied()
                                                else error = context.getString(R.string.remote_camera_tool_failed)
                                            }
                                        }
                                    } catch (cancelled: CancellationException) { throw cancelled }
                                    catch (e: Exception) {
                                        error = context.getString(R.string.remote_camera_tool_failed)
                                        log("!! camera tool write ${tool.name}: ${e.javaClass.simpleName}")
                                    } finally {
                                        if (acquired) access.unlock()
                                        busy = false
                                    }
                                }
                            }.padding(horizontal = 20.dp, vertical = 13.dp), verticalAlignment = Alignment.CenterVertically) {
                            Text(label(p, value), color = if (selected) colors.accentBlue else colors.onBackground,
                                style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
                            if (selected) Icon(Icons.Default.Check, null, tint = colors.accentBlue, modifier = Modifier.size(18.dp))
                        }
                    }
                }
            }
        }
    }
}
