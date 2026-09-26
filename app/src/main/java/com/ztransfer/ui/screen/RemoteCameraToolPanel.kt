package com.ztransfer.ui.screen

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.TouchApp
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.platform.LocalContext
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
internal fun cameraToolLabelResource(tool: RemoteCameraTool, prop: Int, value: Long, model: String? = null, dataType: Int? = null): Int? = when (tool) {
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
    RemoteCameraTool.FOCUS_AREA -> focusAreaLabelResource(prop, value, model, dataType)
}

// PTP mappings: libgphoto2 camlibs/ptp2/config.c (Nikon_D7100/D850_FocusMetering,
// Nikon_LiveViewAF). Do not reuse DSLR point counts for an unknown body.
private fun focusAreaLabelResource(prop: Int, value: Long, model: String?, dataType: Int?): Int? {
    val body = model.orEmpty().trim().uppercase(java.util.Locale.ROOT).removePrefix("NIKON").trim()
    if (prop == 0xD05D && dataType in listOf(0x0001, 0x0002)) {
        return when (value) {
            0L -> R.string.remote_af_face_priority
            1L -> R.string.remote_af_wide
            2L -> R.string.remote_af_normal
            3L -> R.string.remote_af_subject_tracking
            4L -> R.string.remote_af_spot
            else -> null
        }
    }
    if (prop == 0x501C && body in listOf("D7100", "D850")) {
        val specific = when (value) {
            2L -> if (body == "D7100") R.string.remote_af_dynamic_9 else R.string.remote_af_dynamic_25
            0x8013L -> if (body == "D7100") R.string.remote_af_dynamic_21 else R.string.remote_af_dynamic_72
            0x8014L -> if (body == "D7100") R.string.remote_af_dynamic_51 else R.string.remote_af_dynamic_153
            0x8016L -> if (body == "D850") R.string.remote_af_dynamic_9 else null
            else -> null
        }
        if (specific != null) return specific
    }
    return if (prop in listOf(0x501C, 0xD05D, 0xD1F8)) when (value) {
        2L -> if (prop == 0x501C && body.startsWith("Z")) R.string.remote_af_dynamic else null
        0x8010L -> R.string.remote_af_single
        0x8011L -> R.string.remote_af_auto
        0x8012L -> if (body.startsWith("Z") || body in listOf("D7100", "D850")) R.string.remote_af_tracking else null
        0x8015L -> R.string.remote_af_group
        0x8017L -> R.string.remote_af_pinpoint
        0x8018L -> R.string.remote_af_wide_s
        0x8019L -> R.string.remote_af_wide_l
        0x801AL -> R.string.remote_af_wide_people
        0x801BL -> R.string.remote_af_wide_animals
        0x8020L -> R.string.remote_af_auto_people
        0x8021L -> R.string.remote_af_auto_animals
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
    anchor: androidx.compose.ui.geometry.Rect? = null,
    closeRequested: Boolean = false,
    landscape: Boolean = false,
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
    val progress = remember { androidx.compose.animation.core.Animatable(0f) }
    var closing by remember { mutableStateOf(false) }
    val latestDismiss by rememberUpdatedState(onDismiss)
    val close: () -> Unit = {
        if (!closing) {
            closing = true
            scope.launch {
                progress.animateTo(0f, androidx.compose.animation.core.tween(120))
                latestDismiss()
            }
        }
    }
    LaunchedEffect(Unit) {
        withFrameNanos { }
        if (!closing) progress.animateTo(1f, androidx.compose.animation.core.tween(160,
            easing = androidx.compose.animation.core.FastOutSlowInEasing))
    }
    LaunchedEffect(closeRequested) { if (closeRequested) close() }
    fun label(p: RcParam, value: Long): String = cameraToolLabelResource(tool, p.prop, value, camera?.deviceModel, p.dataType)?.let(context::getString)
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
    androidx.activity.compose.BackHandler { close() }
    BoxWithConstraints(Modifier.fillMaxSize()) {
    val density = androidx.compose.ui.platform.LocalDensity.current
    val gap = 6.dp
    val margin = 8.dp
    val anchorTop = with(density) { (anchor?.top ?: 0f).toDp() }
    val anchorBottom = with(density) { (anchor?.bottom ?: 0f).toDp() }
    // Use this rotated host's dimensions and local anchor, never the physical window dimensions.
    val menuMaxHeight = (if (landscape) anchorTop - gap - margin
        else maxHeight - anchorBottom - gap - margin).coerceAtLeast(1.dp)
    val textMeasurer = androidx.compose.ui.text.rememberTextMeasurer()
    val labelStyle = MaterialTheme.typography.bodyMedium
    fun hasTapMarker(p: RcParam, value: Long) =
        tool == RemoteCameraTool.FOCUS_AREA && p.prop in listOf(0x501C, 0xD05D, 0xD1F8) &&
            value in listOf(0x8011L, 0x8020L, 0x8021L)
    // Measure only the connected camera's rows; unsupported long labels must not widen this menu.
    val labelWidth = param?.let { p ->
        (p.values + p.current).distinct().maxOfOrNull { value ->
            with(density) { textMeasurer.measure(label(p, value), labelStyle).size.width.toDp() } +
                if (hasTapMarker(p, value)) 22.dp else 0.dp
        }
    } ?: 100.dp
    val menuWidth = (labelWidth + 24.dp).coerceIn(124.dp,
        (maxWidth - 16.dp).coerceAtLeast(124.dp).coerceAtMost(280.dp))
    val panelContent: @Composable () -> Unit = {
        Box(
            modifier = Modifier.width(menuWidth).heightIn(max = menuMaxHeight)
                .graphicsLayer {
                    alpha = progress.value
                    // Always start next to the button; no moving scale pivot or long travel.
                    translationY = (if (landscape) 1f else -1f) * 4.dp.toPx() * (1f - progress.value)
                }
                .clip(RoundedCornerShape(12.dp))
                .background(colors.surface),
        ) {
            Column(Modifier.padding(vertical = 4.dp)) {
                if (loading || busy) LinearProgressIndicator(Modifier.fillMaxWidth().padding(horizontal = 12.dp), color = colors.accentBlue)
                val p = param
                if (!loading && (p == null || !p.writable || p.values.isEmpty())) Text(
                    stringResource(R.string.remote_camera_tool_unavailable), color = colors.onSurfaceVariant,
                    style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(horizontal = 12.dp, vertical = 12.dp))
                error?.let { Text(it, color = colors.accentOrange, style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp)) }
                if (p != null) LazyColumn(Modifier.weight(1f, fill = false)) {
                    items((p.values + p.current).distinct(), key = { it }) { value ->
                        val selected = value == p.current
                        Row(Modifier.fillMaxWidth().background(if (selected) colors.accentBlue.copy(alpha = 0.08f) else androidx.compose.ui.graphics.Color.Transparent)
                            .clickable(enabled = !closing && !busy && canWrite && p.writable && value in p.values) {
                                if (selected) { close(); return@clickable }
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
                                                if (result.confirmed) {
                                                    onApplied()
                                                    close()
                                                }
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
                            }.padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                            Box(Modifier.weight(1f)) {
                                val name = label(p, value)
                                val qualifier = name.indexOfAny(charArrayOf('（', '('))
                                Text(
                                    text = androidx.compose.ui.text.buildAnnotatedString {
                                        if (qualifier < 0) append(name) else {
                                            append(name.substring(0, qualifier))
                                            pushStyle(androidx.compose.ui.text.SpanStyle(color = if (selected) colors.accentBlue else colors.onSurfaceVariant))
                                            append(name.substring(qualifier))
                                            pop()
                                        }
                                    },
                                    color = if (selected) colors.accentBlue else colors.onBackground,
                                    style = MaterialTheme.typography.bodyMedium,
                                )
                            }
                            if (hasTapMarker(p, value)) {
                                Spacer(Modifier.width(6.dp))
                                Icon(
                                    Icons.Default.TouchApp,
                                    contentDescription = stringResource(R.string.remote_af_tap_badge),
                                    tint = if (selected) colors.accentBlue else colors.onSurfaceVariant,
                                    modifier = Modifier.size(16.dp),
                                )
                            }
                        }
                    }
                }
            }
        }
    }
    // Transparent dismissal layer belongs to the same rotated host. It consumes outside taps
    // so dismissing the list cannot accidentally focus or trigger a camera control underneath.
    Box(Modifier.matchParentSize().clickable(
        interactionSource = remember { androidx.compose.foundation.interaction.MutableInteractionSource() },
        indication = null,
    ) { close() })
    androidx.compose.ui.layout.Layout(
        content = {
            Box(Modifier.clickable(
                interactionSource = remember { androidx.compose.foundation.interaction.MutableInteractionSource() },
                indication = null,
            ) { /* Consume taps in the panel's padding. */ }) { panelContent() }
        },
        modifier = Modifier.fillMaxSize(),
    ) { measurables, constraints ->
        val panel = measurables.single().measure(constraints.copy(minWidth = 0, minHeight = 0))
        val inset = margin.roundToPx()
        val spacing = gap.roundToPx()
        val left = (anchor?.left?.toInt() ?: inset)
            .coerceIn(inset, (constraints.maxWidth - panel.width - inset).coerceAtLeast(inset))
        val top = if (landscape) (anchor?.top?.toInt() ?: constraints.maxHeight) - spacing - panel.height
            else (anchor?.bottom?.toInt() ?: inset) + spacing
        layout(constraints.maxWidth, constraints.maxHeight) {
            panel.place(left, top.coerceIn(0, (constraints.maxHeight - panel.height).coerceAtLeast(0)))
        }
    }
    }
}
