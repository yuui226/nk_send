"""W24 exact product queue visuals extraction; Android retains lifecycle collection/resources."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
ANDROID = "app/src/main/java/com/ztransfer/ui/screen/FileListScreen.kt"
COMMON = "shared/src/commonMain/kotlin/com/ztransfer/ui/screen/SharedQueueWorkspace.kt"
BASELINE = "ad101d5"
HEADER = """@file:OptIn(kotlin.experimental.ExperimentalObjCRefinement::class)

package com.ztransfer.ui.screen

import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.*
import androidx.compose.foundation.interaction.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Checklist
import androidx.compose.material.icons.filled.Photo
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.*
import androidx.compose.ui.graphics.*
import androidx.compose.ui.layout.*
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.ztransfer.ui.theme.*
import com.ztransfer.ui.util.Haptics
import com.ztransfer.viewmodel.ActiveTransferProgress
import com.ztransfer.viewmodel.TransferTask
import kotlinx.coroutines.delay

"""

def extract(source):
    helpers_start = source.index("internal data class QueuePillWidthKey(")
    helpers_end = source.index("private const val REMOTE_BUSY_VISUAL_DELAY_MS", helpers_start)
    helpers = source[helpers_start:helpers_end]
    pill_start = source.index("@Composable\nfun QueuePill(")
    pill_end = source.index("internal data class FilterButtonPalette(", pill_start)
    pill = source[pill_start:pill_end]
    flight_start = source.index("private data class PackSoul(")
    flight_end = source.index("/**\n * 连拍检测：", flight_start)
    flight = source[flight_start:flight_end]
    shared_pill = pill.replace("fun QueuePill(", "fun SharedQueuePill(")
    shared_pill = shared_pill.replace("    transferState: com.ztransfer.viewmodel.TransferState,\n    activeProgressFlow: StateFlow<ActiveTransferProgress?>,",
        "    tasks: List<TransferTask>,\n    isTransferring: Boolean,\n    liveProgressSource: @Composable () -> ActiveTransferProgress?,")
    shared_pill = shared_pill.replace("    heldCount: Int = 0\n", "    heldCount: Int = 0,\n    formatSpeed: (Long) -> String,\n    transferDescription: String,\n    generatingLabel: String,\n")
    shared_pill = shared_pill.replace("val liveProgress by activeProgressFlow.collectAsStateWithLifecycle()", "val liveProgress = liveProgressSource()")
    shared_pill = shared_pill.replace("transferState.tasks", "tasks").replace("transferState.isTransferring", "isTransferring")
    shared_pill = shared_pill.replace("?.let(::formatSpeed)", "?.let(formatSpeed)")
    shared_pill = shared_pill.replace("stringResource(R.string.cd_transfer)", "transferDescription")
    shared_pill = shared_pill.replace("stringResource(R.string.queue_pill_generating)", "generatingLabel")
    signature = pill[:pill.index(") {") + 3]
    wrapper = signature + """
    SharedQueuePill(transferState.tasks, transferState.isTransferring,
        liveProgressSource = { activeProgressFlow.collectAsStateWithLifecycle().value },
        haptics = haptics, onClick = onClick, heldCount = heldCount, formatSpeed = ::formatSpeed,
        transferDescription = stringResource(R.string.cd_transfer),
        generatingLabel = stringResource(R.string.queue_pill_generating))
}

"""
    common = HEADER + helpers.replace("internal data class QueuePillWidthKey", "data class QueuePillWidthKey").replace(
        "internal fun queuePillWidthKey", "fun queuePillWidthKey") + shared_pill + flight.replace(
        "private data class PackSoul", "data class PackSoul").replace("private data class QueueFlight", "data class QueueFlight").replace(
        "private const val MAX_PACK_GHOSTS", "const val MAX_PACK_GHOSTS").replace("private fun QueueFlightGhost", "fun QueueFlightGhost")
    for declaration in ("fun SharedQueuePill(", "fun QueueFlightGhost(", "data class PackSoul(", "data class QueueFlight("):
        common = common.replace(declaration, "@kotlin.native.HiddenFromObjC\n" + declaration)
    android = source[:flight_start] + source[flight_end:]
    android = android[:pill_start] + wrapper + android[pill_end:]
    android = android[:helpers_start] + android[helpers_end:]
    return android, common.rstrip() + "\n"

def verify(root=ROOT):
    source = subprocess.check_output(["git", "show", BASELINE + ":" + ANDROID], cwd=root).decode("utf8")
    android, common = extract(source)
    assert (root / ANDROID).read_text(encoding="utf8") == android, "Android queue workspace extraction changed"
    assert (root / COMMON).read_text(encoding="utf8") == common, "Shared queue workspace extraction changed"

def previous_queue_workspace_source(path, value):
    if path != ANDROID:
        return value
    source = subprocess.check_output(["git", "show", BASELINE + ":" + ANDROID], cwd=ROOT).decode("utf8")
    assert value == extract(source)[0], "Android queue workspace adapter changed"
    return source
