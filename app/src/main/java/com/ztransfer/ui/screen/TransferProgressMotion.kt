package com.ztransfer.ui.screen

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.AnimationVector1D
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.snapshotFlow
import com.ztransfer.ui.theme.Motion
import com.ztransfer.viewmodel.TransferStatus
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch

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
 * 只接受向前的进度，过滤协议采样或状态切换造成的短暂回退。目标更新时先保存速度再
 * 取消旧动画；避免 LaunchedEffect 随目标重启时，Animatable 已把速度清零。
 */
@Composable
internal fun rememberSmoothTransferProgress(
    targetProgress: Float,
    resetKey: Any?,
): Animatable<Float, AnimationVector1D> {
    val latestTarget by rememberUpdatedState(normalizedTransferProgress(targetProgress))
    val animated = remember(resetKey) { Animatable(0f) }
    LaunchedEffect(animated) {
        var acceptedTarget = 0f
        var progressJob: Job? = null
        try {
            snapshotFlow { latestTarget }.collect { target ->
                // Duplicate and older samples must not cancel an animation already in flight.
                if (target <= acceptedTarget) return@collect
                acceptedTarget = target
                val velocity = animated.velocity
                progressJob?.cancelAndJoin()
                progressJob = launch {
                    animated.animateTo(target, Motion.progress, initialVelocity = velocity)
                }
            }
        } finally {
            progressJob?.cancel()
        }
    }
    return animated
}
