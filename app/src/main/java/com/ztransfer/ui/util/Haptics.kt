package com.ztransfer.ui.util

import android.os.Build
import android.view.HapticFeedbackConstants
import android.view.View
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalView

/**
 * 语义化触感反馈：调用点只表达"发生了什么"，由此处映射到系统震动常量。
 * [enabled] 为 false（设置开关默认开启，用户可关）时所有调用零开销 no-op；
 * 系统全局"触摸震动"设置关闭时由 performHapticFeedback 自行忽略，双重尊重用户意愿。
 */
class Haptics(private val view: View, private val enabled: Boolean) {

    /** 轻点入队（单张 / 整组各一次）：最细的 tick，短促细腻。 */
    fun tick() {
        if (enabled) view.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
    }

    /** 长按弹出预览：系统标准长按震感。 */
    fun longPress() {
        if (enabled) view.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
    }

    /** 全部传输完成（确实传了东西，纯"已存在跳过"不震）：成功确认震。 */
    fun success() {
        if (!enabled) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            view.performHapticFeedback(HapticFeedbackConstants.CONFIRM)
        } else {
            view.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
        }
    }
}

@Composable
fun rememberHaptics(enabled: Boolean): Haptics {
    val view = LocalView.current
    return remember(view, enabled) { Haptics(view, enabled) }
}
