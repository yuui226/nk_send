"""Auditable, narrow transforms from the Android baseline; never edits files itself."""
import re

HEADER = """package com.ztransfer.ui.screen

import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.*
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.ztransfer.ui.theme.*
import com.ztransfer.viewmodel.TransferStatus
import com.ztransfer.viewmodel.TransferTask

/** Already-localized display values. No camera service, Android resources or number formatter here. */
data class TransferTaskCardText(
    val speedText: String?,
    val transferDuration: String?,
    val generationDuration: String?,
    val effectText: String?,
    val fileSizeText: String,
    val failureText: String,
)

"""


def replace_once(source, old, new):
    if source.count(old) != 1:
        raise ValueError(f"Unexpected extraction anchor: {old[:90]!r}")
    return source.replace(old, new, 1)


def extract_transfer_cards(source):
    source = source.replace("\r\n", "\n")
    start = source.index("private fun transferCardVisualState(")
    end = source.index("@Composable\nprivate fun transferTaskEffectText(", start)
    old_cards = source[start:end]
    cards = old_cards
    enums = []
    for name in ("TransferCardPillTone", "TransferCardVisualState"):
        declaration = re.search(rf"private enum class {name} \{{[^\n]+\}}\n\n", source)
        if not declaration:
            raise ValueError(f"Missing original enum {name}")
        enums.append(declaration.group())
    cards = replace_once(cards, "private fun TransferRetryButton(", "fun SharedTransferRetryButton(")
    cards = replace_once(cards, "    onClick: () -> Unit,\n    modifier: Modifier", "    onClick: () -> Unit,\n    contentDescription: String,\n    modifier: Modifier")
    cards = replace_once(cards, "contentDescription = stringResource(R.string.retry)", "contentDescription = contentDescription")
    cards = replace_once(cards, "private fun transferCardStateColor(", "fun transferCardStateColor(")
    cards = replace_once(cards, "private fun TaskStatusBadge(", "fun TaskStatusBadge(")
    cards = replace_once(cards, "private fun TransferTaskCardContent(", "fun SharedTransferTaskCardContent(")
    cards = replace_once(cards, "    displayedSpeed: Long,\n    displayedFrameGenerationElapsedMs: Long?,", "    text: TransferTaskCardText,")
    calc_start = old_cards.index("    val transferred = task.status == TransferStatus.COMPLETED")
    calc_end = old_cards.index("    val animateTransferPills", calc_start)
    calculations = old_cards[calc_start:calc_end]
    cards = replace_once(cards, calculations, """    val speedText = text.speedText
    val transferDuration = text.transferDuration
    val generationDuration = text.generationDuration
    val effectText = text.effectText
""")
    cards = replace_once(cards, "text = transferTaskFileSizeText(task)", "text = text.fileSizeText")
    cards = replace_once(cards, "text = task.error ?: stringResource(R.string.transfer_failed)", "text = text.failureText")
    wrappers = """@Composable
private fun TransferRetryButton(
    visible: Boolean,
    enabled: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    SharedTransferRetryButton(visible, enabled, onClick, stringResource(R.string.retry), modifier)
}

@Composable
private fun TransferTaskCardContent(
    task: TransferTask,
    displayedSpeed: Long,
    displayedFrameGenerationElapsedMs: Long?,
    modifier: Modifier = Modifier,
) {
""" + calculations + """    SharedTransferTaskCardContent(
        task = task,
        text = TransferTaskCardText(
            speedText = speedText,
            transferDuration = transferDuration,
            generationDuration = generationDuration,
            effectText = effectText,
            fileSizeText = transferTaskFileSizeText(task),
            failureText = task.error ?: if (task.status == TransferStatus.FAILED) stringResource(R.string.transfer_failed) else "",
        ),
        modifier = modifier,
    )
}

"""
    confirm_start = source.index('/**\n * 右下角悬浮的')
    confirm_end = source.index('/**\n * 传输队列行内的', confirm_start)
    old_confirm = source[confirm_start:confirm_end]
    confirm = replace_once(old_confirm, "private fun ConfirmFab(", "fun SharedQueueConfirmFab(")
    dismiss_signature = "    onDismiss: () -> Unit,\n    subtitle"
    if confirm.count(dismiss_signature) != 2:
        raise ValueError("Expected FAB and confirmation card signatures")
    confirm = confirm.replace(dismiss_signature, "    onDismiss: () -> Unit,\n    cancelText: String,\n    subtitle")
    confirm = replace_once(confirm, "                onDismiss = onDismiss\n", "                onDismiss = onDismiss,\n                cancelText = cancelText,\n")
    confirm = replace_once(confirm, "Text(stringResource(R.string.cancel),", "Text(cancelText,")
    signature = old_confirm[:old_confirm.index(") {\n") + len(") {\n")]
    confirm_wrapper = signature + """    SharedQueueConfirmFab(
        expanded = expanded, icon = icon, title = title, confirmText = confirmText,
        confirmColor = confirmColor, onToggle = onToggle, onConfirm = onConfirm,
        onDismiss = onDismiss, cancelText = stringResource(R.string.cancel),
        subtitle = subtitle, enabled = enabled, modifier = modifier,
    )
}

"""
    thumbnail_start = source.index("private fun QueueThumbnail(")
    box_start = source.index("    Box(\n", thumbnail_start)
    old_thumbnail_body = source[box_start:].rstrip() + "\n"
    thumbnail = """/** Presentation only; request/cache/retry ownership remains with the platform caller. */
@Composable
fun QueueThumbnailContent(thumbnail: ImageBitmap?, modifier: Modifier = Modifier) {
""" + old_thumbnail_body
    android = replace_once(source, old_cards, wrappers)
    android = replace_once(android, old_confirm, confirm_wrapper)
    android = replace_once(android, source[box_start:], "    QueueThumbnailContent(thumbnail, modifier)\n}\n")
    for declaration in enums:
        android = replace_once(android, declaration, "")
    return android, HEADER + "".join(enums) + cards + confirm + thumbnail
