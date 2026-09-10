"""Reviewed Genie presentation changes; historical text is only a fail-closed IO oracle."""

POPUP = [
    ("import androidx.compose.ui.graphics.graphicsLayer",
     "import androidx.compose.ui.graphics.graphicsLayer\nimport androidx.compose.ui.graphics.rememberGraphicsLayer"),
    (" * [morphFromAnchor] 用于设置：从按钮下缘独立展开和收回，无黏连，也不牵动入口按钮。",
     " * [morphFromAnchor] 保留独立展开；[genieFromAnchor] 试验整块内容的漏斗形收束。"),
    ("    morphFromAnchor: Boolean = false,",
     "    morphFromAnchor: Boolean = false,\n    genieFromAnchor: Boolean = false,"),
    ("    val colors = AppTheme.colors",
     "    val colors = AppTheme.colors\n    val genieLayer = if (genieFromAnchor) rememberGraphicsLayer() else null"),
    ("                progress.animateTo(0f, if (morphFromAnchor) {",
     "                progress.animateTo(0f, if (morphFromAnchor || genieFromAnchor) {"),
    ("                                progress.animateTo(1f, if (morphFromAnchor) {",
     "                                progress.animateTo(1f, if (morphFromAnchor || genieFromAnchor) {"),
    ("                    if (morphFromAnchor) {",
     "                    if (morphFromAnchor && !genieFromAnchor) {"),
    ("            Surface(\n                modifier = Modifier\n                    .graphicsLayer {",
     "            Surface(\n                modifier = Modifier\n                    .then(if (genieLayer != null) Modifier.geniePopupLayer(\n                        layer = genieLayer,\n                        progress = { progress.value },\n                        anchor = { anchorBounds },\n                        panel = { animationState.panelBounds },\n                    ) else Modifier)\n                    .graphicsLayer {"),
    ("                        if (morphFromAnchor && size.width > 0f && size.height > 0f) {",
     "                        if (genieFromAnchor) {\n                            // The complete, unscaled surface is warped by the outer layer.\n                            alpha = 1f\n                            scaleX = 1f\n                            scaleY = 1f\n                        } else if (morphFromAnchor && size.width > 0f && size.height > 0f) {"),
    ("                color = if (morphFromAnchor) Color.Transparent else colors.glassSurfaceHeavy,",
     "                color = if (morphFromAnchor && !genieFromAnchor) Color.Transparent else colors.glassSurfaceHeavy,"),
    ("                border = if (morphFromAnchor) null else BorderStroke(1.dp, colors.glassPanelBorder),",
     "                border = if (morphFromAnchor && !genieFromAnchor) null else BorderStroke(1.dp, colors.glassPanelBorder),"),
    ("                    tween((260 * progress.value).toInt().coerceAtLeast(1), easing = LinearEasing)",
     "                    tween((260 * progress.value).toInt().coerceAtLeast(1),\n                        easing = if (genieFromAnchor) GenieCollapseEasing else LinearEasing)"),
    ("                                    tween(320, easing = LinearEasing)",
     "                                    tween(320,\n                                        easing = if (genieFromAnchor) GenieExpandEasing else LinearEasing)"),
]

WRAPPER = [
    ("    morphFromAnchor: Boolean = false,",
     "    morphFromAnchor: Boolean = false,\n    genieFromAnchor: Boolean = false,"),
    ("        morphFromAnchor = morphFromAnchor,",
     "        morphFromAnchor = morphFromAnchor,\n        genieFromAnchor = genieFromAnchor,"),
]

SETTINGS = [
    ("        morphFromAnchor = true,",
     "        genieFromAnchor = true,"),
]

# Remove the superseded split/scale renderer, not any popup content or event handling.
CLEANUP = [
    ("import androidx.compose.animation.core.LinearEasing\n", ""),
    ("import androidx.compose.ui.geometry.Offset\nimport androidx.compose.ui.geometry.Size\n"
     "import androidx.compose.ui.geometry.CornerRadius\nimport androidx.compose.ui.graphics.drawscope.Stroke\n", ""),
    (" * [morphFromAnchor] 保留独立展开；[genieFromAnchor] 试验整块内容的漏斗形收束。",
     " * [genieFromAnchor] 用于设置和筛选：整块内容向按钮下缘斜向收束。"),
    ("    morphFromAnchor: Boolean = false,\n", ""),
    ("                progress.animateTo(0f, if (morphFromAnchor || genieFromAnchor) {",
     "                progress.animateTo(0f, if (genieFromAnchor) {"),
    ("easing = if (genieFromAnchor) GenieCollapseEasing else LinearEasing", "easing = GenieCollapseEasing"),
    ("        // The shell is drawn at animated bounds; the settings tree is measured at its final size.",
     "        // Content is measured at its final size; only drawing changes during the transition."),
    ("                                progress.animateTo(1f, if (morphFromAnchor || genieFromAnchor) {",
     "                                progress.animateTo(1f, if (genieFromAnchor) {"),
    ("easing = if (genieFromAnchor) GenieExpandEasing else LinearEasing", "easing = GenieExpandEasing"),
    ("""                }
                .drawBehind {
                    if (morphFromAnchor && !genieFromAnchor) {
                        val panel = animationState.panelBounds ?: Rect(0f, 0f, size.width, size.height)
                        val frame = settingsPopupFrame(progress.value, anchorBounds, panel, 20.dp.toPx())
                        val topLeft = Offset(frame.bounds.left - panel.left, frame.bounds.top - panel.top)
                        val frameSize = Size(frame.bounds.width, frame.bounds.height)
                        val radius = CornerRadius(frame.cornerRadius)
                        drawRoundRect(colors.glassSurfaceHeavy, topLeft, frameSize, radius,
                            alpha = frame.shellAlpha)
                        drawRoundRect(colors.glassPanelBorder, topLeft, frameSize, radius,
                            alpha = frame.shellAlpha, style = Stroke(1.dp.toPx()))
                    }
                },""", "                },"),
    ("""                        } else if (morphFromAnchor && size.width > 0f && size.height > 0f) {
                            val panel = b ?: Rect(0f, 0f, size.width, size.height)
                            val frame = settingsPopupFrame(p, anchorBounds, panel, 20.dp.toPx())
                            transformOrigin = TransformOrigin(0f, 0f)
                            translationX = frame.bounds.left - panel.left
                            translationY = frame.bounds.top - panel.top
                            scaleX = frame.bounds.width / size.width
                            scaleY = frame.bounds.height / size.height
                            alpha = frame.contentAlpha
""", ""),
    ("color = if (morphFromAnchor && !genieFromAnchor) Color.Transparent else colors.glassSurfaceHeavy,",
     "color = colors.glassSurfaceHeavy,"),
    ("border = if (morphFromAnchor && !genieFromAnchor) null else BorderStroke(1.dp, colors.glassPanelBorder),",
     "border = BorderStroke(1.dp, colors.glassPanelBorder),"),
]

def transform(source, edits, reverse=False):
    for old, new in reversed(edits) if reverse else edits:
        before, after = (new, old) if reverse else (old, new)
        if source.count(before) != 1:
            raise ValueError("Genie experiment anchor changed: " + before[:80])
        source = source.replace(before, after, 1)
    return source


def apply_genie_popup(source):
    return transform(transform(source, POPUP), CLEANUP)


def apply_genie_wrapper(source):
    if "genieFromAnchor" in source:
        raise ValueError("Genie wrapper is already adapted")
    return transform(transform(source, WRAPPER), [
        ("    morphFromAnchor: Boolean = false,\n", ""),
        ("        morphFromAnchor = morphFromAnchor,\n", ""),
    ])


def restore_genie_settings(source):
    return transform(source, SETTINGS, reverse=True)


def apply_genie_filter(source):
    return transform(source, [("        animateScale = false,",
        "        animateScale = false,\n        genieFromAnchor = true,")])
