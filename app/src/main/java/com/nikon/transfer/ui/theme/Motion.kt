package com.nikon.transfer.ui.theme

import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.FiniteAnimationSpec
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.SpringSpec
import androidx.compose.animation.core.TweenSpec
import androidx.compose.animation.core.VisibilityThreshold
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.ui.unit.IntOffset

/**
 * 全局动画规格：手感参数集中一处，改这里全局生效。
 * 一次性的微交互（如信号按钮 dBm 收起的干脆利落 tween）留在使用处，不强行入库。
 */
object Motion {
    /** 弹性尺寸变化（顶栏胶囊宽度、信号按钮展开等"内容变了、容器跟着弹"）。 */
    fun <T> bouncy(): SpringSpec<T> = spring(
        dampingRatio = Spring.DampingRatioMediumBouncy,
        stiffness = Spring.StiffnessMediumLow
    )

    /** 覆盖层"从锚点变形展开/收回"（设置面板、长按预览共用，保证节奏一致）。 */
    val overlayExpand: TweenSpec<Float> = tween(340, easing = FastOutSlowInEasing)
    val overlayCollapse: TweenSpec<Float> = tween(260, easing = FastOutSlowInEasing)

    /**
     * "Z传"页 ↔ 队列页左右滑动转场：进/出双方共用同一弹簧——弹簧位移与初始距离成正比，
     * 上层整页与底层 1/3 视差才全程同步；临界阻尼，横向整页滑动过冲会露出屏幕边缘。
     */
    val pageSlide: FiniteAnimationSpec<IntOffset> = spring(
        dampingRatio = Spring.DampingRatioNoBouncy,
        stiffness = 380f,
        visibilityThreshold = IntOffset.VisibilityThreshold
    )

    /** NavHost 默认缩放淡入转场（连接页 ↔ "Z传"页）与滑动转场的配套淡变时长。 */
    const val NAV_ENTER_MS = 420
    const val NAV_EXIT_MS = 280
    const val PAGE_FADE_MS = 320

    /**
     * 列表/网格条目的位移动画（分组收起/展开时后续内容弹到新位置）：
     * 轻微欠阻尼，有一点弹性但不会荡过头。
     */
    val itemPlacement: FiniteAnimationSpec<IntOffset> = spring(
        dampingRatio = 0.8f,
        stiffness = 380f,
        visibilityThreshold = IntOffset.VisibilityThreshold
    )
}
