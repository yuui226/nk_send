package com.ztransfer.ui.util

import android.os.Build
import android.view.HapticFeedbackConstants
import android.view.View
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalView

/**
 * 语义化触感反馈：调用点只表达"发生了什么"，由此处映射到系统震动常量。
 * [enabled] 为 false（设置开关默认开启，用户可关）时所有调用零开销 no-op；
 * 系统全局"触摸震动"设置关闭时由 performHapticFeedback 自行忽略，双重尊重用户意愿。
 */
class Haptics(private val view: View, private val enabled: Boolean) {
    private val vibrator: Vibrator? by lazy {
        val context = view.context.applicationContext
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            context.getSystemService(VibratorManager::class.java)?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            context.getSystemService(Vibrator::class.java)
        }
    }

    /** 轻点入队（单张 / 整组各一次）：最细的 tick，短促细腻。 */
    fun tick() {
        if (enabled) view.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
    }

    /** 长按弹出预览：系统标准长按震感。 */
    fun longPress() {
        if (enabled) view.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
    }

    /** 成功确认：用于连接建立、有效传输完成等明确完成事件。 */
    fun success() {
        if (!enabled) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            view.performHapticFeedback(HapticFeedbackConstants.CONFIRM)
        } else {
            view.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
        }
    }

    /**
     * 长按蓄力使用单条渐强波形，避免高频 performHapticFeedback 被系统合并或限频。
     * 波形末尾刻意留白；只有真正按满后 [completeProgressiveHold] 才补上独立确认脉冲。
     */
    fun startProgressiveHold() {
        if (!enabled) return
        val device = vibrator?.takeIf { it.hasVibrator() } ?: return
        device.cancel()
        device.vibrate(
            VibrationEffect.createWaveform(
                PROGRESSIVE_HOLD_TIMINGS_MS,
                PROGRESSIVE_HOLD_AMPLITUDES,
                -1,
            )
        )
    }

    /** 手指提前松开时立即停止尚未完成的蓄力反馈。 */
    fun cancelProgressiveHold() {
        if (enabled) vibrator?.cancel()
    }

    /** 按满后使用设备调校过的重点击；旧系统退化为短促脉冲，不使用闷重的长振动。 */
    fun completeProgressiveHold() {
        if (!enabled) return
        val device = vibrator?.takeIf { it.hasVibrator() } ?: return
        device.cancel()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            device.vibrate(
                VibrationEffect.createPredefined(VibrationEffect.EFFECT_HEAVY_CLICK)
            )
        } else {
            device.vibrate(
                VibrationEffect.createOneShot(
                    PROGRESSIVE_HOLD_CONFIRM_DURATION_MS,
                    PROGRESSIVE_HOLD_CONFIRM_AMPLITUDE,
                )
            )
        }
    }

    /** 操作失败：新系统使用拒绝触感，旧系统以两次轻 tick 与成功确认明确区分。 */
    fun failure() {
        if (!enabled) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            view.performHapticFeedback(HapticFeedbackConstants.REJECT)
        } else {
            view.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
            view.postDelayed({
                if (view.isAttachedToWindow) {
                    view.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
                }
            }, FAILURE_SECOND_TICK_DELAY_MS)
        }
    }
}

@Composable
fun rememberHaptics(enabled: Boolean): Haptics {
    val view = LocalView.current
    return remember(view, enabled) { Haptics(view, enabled) }
}

private const val FAILURE_SECOND_TICK_DELAY_MS = 65L

const val PROGRESSIVE_HOLD_HAPTIC_DURATION_MS = 800
private const val PROGRESSIVE_HOLD_CONFIRM_DURATION_MS = 18L
private const val PROGRESSIVE_HOLD_CONFIRM_AMPLITUDE = 220

// Ten very short impulses accelerate from 120 ms to 45 ms apart and gradually gain strength.
// The last 63 ms stay silent so the independent completion click has a clean leading edge.
private val PROGRESSIVE_HOLD_TIMINGS_MS = longArrayOf(
    0L,
    8L, 112L,
    8L, 102L,
    9L, 91L,
    9L, 81L,
    10L, 70L,
    10L, 60L,
    11L, 49L,
    11L, 39L,
    12L, 33L,
    12L, 63L,
)
private val PROGRESSIVE_HOLD_AMPLITUDES = intArrayOf(
    0,
    24, 0,
    28, 0,
    34, 0,
    42, 0,
    52, 0,
    64, 0,
    78, 0,
    96, 0,
    118, 0,
    142, 0,
)
