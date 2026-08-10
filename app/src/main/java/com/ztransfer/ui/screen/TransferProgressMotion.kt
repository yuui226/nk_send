package com.ztransfer.ui.screen

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.AnimationVector1D
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import com.ztransfer.ui.theme.Motion
import com.ztransfer.viewmodel.TransferStatus
import kotlin.math.max

internal fun normalizedTransferProgress(progress: Float): Float =
    if (progress.isFinite()) progress.coerceIn(0f, 1f) else 0f

/** 卡片离场时只有成功完成可以补满；失败和取消保留真实的最后进度。 */
internal fun transferCardProgressTarget(status: TransferStatus, progress: Float): Float =
    if (status == TransferStatus.COMPLETED) 1f else normalizedTransferProgress(progress)

/** 完成补满期间继续保留波浪，失败/取消则直接淡出当前进度。 */
internal fun transferCardWaveEligible(status: TransferStatus): Boolean =
    status == TransferStatus.TRANSFERING || status == TransferStatus.COMPLETED

/**
 * 传输进度统一追值器。
 *
 * 每个 [resetKey] 都从 0 自然起步，避免进度控件首次进入组合时直接闪到当前值；同一任务
 * 只接受向前的进度，过滤协议采样或状态切换造成的短暂回退。Animatable 在目标连续更新时
 * 会保留当前速度，因此频繁进度回调不会反复从静止起步。
 */
@Composable
internal fun rememberSmoothTransferProgress(
    targetProgress: Float,
    resetKey: Any?,
): Animatable<Float, AnimationVector1D> {
    val target = normalizedTransferProgress(targetProgress)
    val animated = remember(resetKey) { Animatable(0f) }
    // 仅由下面的 LaunchedEffect 访问，不参与 UI 状态，也不会引发额外重组。
    val acceptedTarget = remember(resetKey) { floatArrayOf(0f) }

    LaunchedEffect(animated, target) {
        val forwardTarget = max(acceptedTarget[0], target)
        acceptedTarget[0] = forwardTarget
        if (forwardTarget > animated.value) {
            animated.animateTo(forwardTarget, Motion.progress)
        }
    }
    return animated
}
