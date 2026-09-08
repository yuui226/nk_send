"""Exact W07 extraction from 6ab3302. Android keeps platform clock/view/resources and every call site."""
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BASELINE = "6ab3302"
ANDROID = "app/src/main/java/com/ztransfer/ui/screen/HomeScreen.kt"
COMMON = "shared/src/commonMain/kotlin/com/ztransfer/ui/screen/SharedConnectionMethodCard.kt"
RANGES = [
    ("private data class ConnectionCardFeedback(", "private enum class StaConnectButtonState"),
    ("@Composable\nprivate fun WifiModeTabs(", "/** 连接页右上角的轻量订阅标签"),
    ("@Composable\nprivate fun ConnectionModeBadge(", "private const val STA_BUTTON_BREATH_DURATION_MS"),
    ("internal fun freeConnectionPulseProgress(", "@Composable\nprivate fun ResetStaPairingDialog("),
    ("private fun DrawScope.drawPremiumSuccessEffect(", "internal fun connectionHeroProgress("),
]
WRAPPER = "@Composable\nprivate fun ConnectionMethodCard(\n    modifier: Modifier,\n    modeIcon: @Composable (Color, Modifier) -> Unit,\n    title: String,\n    accent: Color,\n    materialSeed: Int,\n    steps: List<String>,\n    modeSelector: (@Composable () -> Unit)? = null,\n    selected: Boolean,\n    success: Boolean,\n    attentionActive: Boolean,\n    attentionPhaseOffset: Float,\n    selectionSceneProgress: () -> Float,\n    successEffectProgress: () -> Float,\n    error: String? = null,\n    goldBurst: Boolean = false,\n    feedback: ConnectionCardFeedback? = null,\n    feedbackFollowsModeSelector: Boolean = false,\n    footer: (@Composable ColumnScope.() -> Unit)? = null,\n    dimmed: Boolean = false,\n    onCardClick: (() -> Unit)? = null,\n) {\n    val view = LocalView.current\n    SharedConnectionMethodCard(\n        failedLabel = stringResource(R.string.connection_failed_short),\n        viewportWidth = view.width.toFloat(), viewportHeight = view.height.toFloat(),\n        uptimeMillis = SystemClock::uptimeMillis,\n        modifier = modifier,\n        modeIcon = modeIcon,\n        title = title,\n        accent = accent,\n        materialSeed = materialSeed,\n        steps = steps,\n        modeSelector = modeSelector,\n        selected = selected,\n        success = success,\n        attentionActive = attentionActive,\n        attentionPhaseOffset = attentionPhaseOffset,\n        selectionSceneProgress = selectionSceneProgress,\n        successEffectProgress = successEffectProgress,\n        error = error,\n        goldBurst = goldBurst,\n        feedback = feedback,\n        feedbackFollowsModeSelector = feedbackFollowsModeSelector,\n        footer = footer,\n        dimmed = dimmed,\n        onCardClick = onCardClick,\n    )\n}\n\n"

def extract(source):
    import re
    chunks = [source[source.index(a):source.index(b, source.index(a))] for a, b in RANGES]
    common = "\n".join(chunks)
    common = common.replace("private data class ConnectionCardFeedback", "data class ConnectionCardFeedback")
    common = common.replace("private fun WifiModeTabs", "fun WifiModeTabs")
    common = common.replace("private fun ConnectionMethodCard(", "fun SharedConnectionMethodCard(\n    failedLabel: String,\n    viewportWidth: Float,\n    viewportHeight: Float,\n    uptimeMillis: () -> Long,")
    common = common.replace("    val view = LocalView.current\n", "")
    common = common.replace("SystemClock.uptimeMillis()", "uptimeMillis()")
    common = common.replace("view.width / 2f", "viewportWidth / 2f").replace("view.height / 3f", "viewportHeight / 3f")
    common = common.replace("stringResource(R.string.connection_failed_short)", "failedLabel")
    common = common.replace("Math.PI", "kotlin.math.PI").replace("internal fun freeConnection", "fun freeConnection")
    imports = "\n".join(line for line in source.splitlines() if line.startswith("import androidx.")
        and not re.search(r"platform.Local(Configuration|Context|View)|ui.res.|lifecycle.viewmodel", line))
    common = ("package com.ztransfer.ui.screen\n\n" + imports +
        "\nimport com.ztransfer.ui.theme.*\nimport com.ztransfer.connection.WirelessMode\nimport kotlinx.coroutines.delay\nimport kotlinx.coroutines.isActive\nimport kotlin.math.cos\nimport kotlin.math.sin\n\nprivate const val CONNECTION_ATTENTION_MS = 2_400\nprivate const val CONNECTION_ATTENTION_FRAME_MS = 8L\n\n" + common)
    android = source
    for index, chunk in enumerate(chunks):
        assert android.count(chunk) == 1
        android = android.replace(chunk.rstrip("\n") + "\n", WRAPPER.rstrip("\n") + "\n" if index == 1 else "", 1)
    return android, common.rstrip() + "\n"

def baseline():
    return subprocess.check_output(["git", "show", BASELINE + ":" + ANDROID], cwd=ROOT).decode("utf-8")

def verify():
    for path, expected in zip((ANDROID, COMMON), extract(baseline())):
        assert (ROOT / path).read_text(encoding="utf-8") == expected, path
