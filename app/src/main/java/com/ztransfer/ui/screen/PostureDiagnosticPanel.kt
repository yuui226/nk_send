package com.ztransfer.ui.screen

import android.os.SystemClock
import android.widget.Toast
import androidx.compose.foundation.layout.*
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.unit.dp
import com.ztransfer.R
import com.ztransfer.ui.theme.AppTheme
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun PostureDiagnosticPanel(collector: PostureDiagnostic, camera: Any?, enabled: Boolean, info: String) {
    val colors = AppTheme.colors
    val scope = rememberCoroutineScope()
    val clipboard = LocalClipboardManager.current
    val context = LocalContext.current
    var count by remember { mutableIntStateOf(collector.count()) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf(false) }
    var job by remember { mutableStateOf<kotlinx.coroutines.Job?>(null) }
    DisposableEffect(camera, enabled, info) {
        onDispose { job?.cancel(); collector.cancel(); busy = false }
    }
    val poses = listOf(R.string.posture_level, R.string.posture_up, R.string.posture_down,
        R.string.posture_left, R.string.posture_right)
    Column(Modifier.fillMaxWidth().padding(vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(stringResource(R.string.posture_title), style = MaterialTheme.typography.labelLarge, color = colors.onBackground)
        Text(stringResource(R.string.posture_hint), style = MaterialTheme.typography.labelSmall, color = colors.onSurfaceVariant)
        Text(if (count == 5) stringResource(R.string.posture_done) else
            "${count + 1}/5 · ${stringResource(poses[count])}",
            style = MaterialTheme.typography.bodySmall, color = colors.onBackground)
        if (error) Text(stringResource(R.string.posture_error), style = MaterialTheme.typography.labelSmall, color = colors.accentOrange)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            if (count < 5) GlassButton(enabled = enabled && camera != null && !busy, onClick = {
                error = false
                if (camera != null && collector.begin(camera, info, SystemClock.elapsedRealtime())) {
                    busy = true
                    job = scope.launch {
                        try {
                            delay(2200)
                            error = !collector.finish()
                            count = collector.count()
                        } finally { collector.cancel(); busy = false }
                    }
                } else error = true
            }) { Text(stringResource(if (busy) R.string.posture_collecting else R.string.posture_capture)) }
            GlassButton(enabled = count > 0 && !busy, onClick = {
                clipboard.setText(AnnotatedString(collector.report()))
                Toast.makeText(context, R.string.code_copied, Toast.LENGTH_SHORT).show()
            }) { Text(stringResource(R.string.posture_copy)) }
            GlassButton(enabled = !busy, onClick = {
                collector.reset(); count = 0; error = false
            }) { Text(stringResource(R.string.posture_reset)) }
        }
    }
}
