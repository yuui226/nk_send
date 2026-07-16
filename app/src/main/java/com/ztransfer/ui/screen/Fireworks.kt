package com.ztransfer.ui.screen

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.unit.dp
import kotlin.math.cos
import kotlin.math.sin

/**
 * 高级版彩蛋——烟花的活跃发数管理：[launch] 每调用一次放一发独立烟花，可连续调用并发；
 * 每发播完自行从 [active] 移除。连接页与照片列表页各持一个实例（[rememberFireworksState]），
 * 徽标点击时 launch()，页面顶层用 [FireworksOverlay] 渲染。
 */
class FireworksState {
    internal val active = mutableStateListOf<Int>()
    private var seq = 0
    fun launch() {
        seq++
        active.add(seq)
    }
}

@Composable
fun rememberFireworksState(): FireworksState = remember { FireworksState() }

/**
 * 渲染当前所有活跃烟花（各自全屏 Canvas、不拦截触摸）。放在页面最上层。
 * 有烟花在放时叠一层淡入的暗幕当"夜空"——否则浅色主题页面上火花会发灰、白热核看不见；
 * 全放完后暗幕淡出，页面恢复。暗幕同样不拦截触摸。
 */
@Composable
fun FireworksOverlay(state: FireworksState) {
    val active = state.active.isNotEmpty()
    // 暗幕透明度：进场快、退场缓（像夜空压下来、再慢慢亮回）。在 draw 里读 .value，只重绘不重组。
    val scrim = animateFloatAsState(
        targetValue = if (active) 0.42f else 0f,
        animationSpec = tween(if (active) 220 else 650, easing = LinearEasing),
        label = "fwScrim"
    )
    Canvas(modifier = Modifier.fillMaxSize()) {
        val a = scrim.value
        if (a > 0.004f) drawRect(Color.Black, alpha = a)
    }
    state.active.forEach { id ->
        key(id) { Firework(seed = id, onFinished = { state.active.remove(id) }) }
    }
}

/**
 * 一发烟花的形态：爆点归一化坐标 [x]/[y]、主火花色 [spark]、粒子数 [n]，以及每颗粒子的
 * 速度倍率 [speed] 与角度抖动 [jitter]（打破完美对称，看起来更自然）。由 seed 确定性生成。
 */
private class FireworkSpec(
    val x: Float, val y: Float,
    val spark: Color, val n: Int,
    val speed: FloatArray, val jitter: FloatArray
)

/**
 * 单发烟花（点一次放一发，可连点并发）。分两段：
 * ①上升：拖尾冲到爆点，临近顶端减速。
 * ②爆炸：起爆一记径向白光闪；随后一圈火花外扩（强 easeOut=空气阻力）、重力下垂（垂柳感）、
 *   每颗＝运动拖尾 comet 尾 + 柔光晕 + 白热核（核心随时间冷却到火花色）+ 尾段闪烁，整体渐隐。
 * 纯 Canvas 逐帧绘制（只读 t.value → 只重绘不重组）、不拦截触摸；[onFinished] 播完回调，
 * 父层据此把本发从活跃列表移除。
 */
@Composable
private fun Firework(seed: Int, onFinished: () -> Unit) {
    val t = remember { Animatable(0f) }
    val done by rememberUpdatedState(onFinished)
    LaunchedEffect(Unit) {
        t.animateTo(1f, tween(1700, easing = LinearEasing))
        done()
    }
    val spec = remember(seed) {
        // 确定性伪随机（xorshift 风格哈希）：同一 seed 稳定，不同 seed 各异，免 Random。
        fun rnd(a: Int): Float {
            var h = (seed * 374761393) xor (a * 668265263)
            h = (h xor (h ushr 13)) * 1274126177
            return ((h xor (h ushr 16)) and 0x7fffffff) / 2147483647f
        }
        val palette = listOf(
            Color(0xFFFFD54F), Color(0xFFFFB74D), Color(0xFF64B5F6),
            Color(0xFF4DD0E1), Color(0xFFEF5350), Color(0xFF81C784),
            Color(0xFFBA68C8), Color(0xFFF06292)
        )
        val n = 48
        val gap = 2f * Math.PI.toFloat() / n
        FireworkSpec(
            x = 0.18f + rnd(1) * 0.64f,
            y = 0.16f + rnd(2) * 0.30f,
            spark = palette[(seed % palette.size + palette.size) % palette.size],
            n = n,
            // 速度分布 0.5..1.0：部分火花飞得更远，爆团有厚度而非一个薄圆环。
            speed = FloatArray(n) { 0.5f + rnd(it * 2 + 10) * 0.5f },
            jitter = FloatArray(n) { (rnd(it * 2 + 11) - 0.5f) * gap }
        )
    }
    Canvas(modifier = Modifier.fillMaxSize()) {
        val prog = t.value
        val launch = 0.22f
        val cx = spec.x * size.width
        val cy = spec.y * size.height
        if (prog < launch) {
            // 上升拖尾 + 柔光 + 白热头，临近顶端减速、拖尾收短。
            val l = prog / launch
            val le = 1f - (1f - l) * (1f - l)
            val y = size.height + (cy - size.height) * le
            val trail = 30.dp.toPx() * (1f - le)
            drawLine(
                spec.spark.copy(alpha = 0.55f),
                start = Offset(cx, y + trail), end = Offset(cx, y),
                strokeWidth = 3f.dp.toPx(), cap = StrokeCap.Round
            )
            drawCircle(spec.spark.copy(alpha = 0.35f), radius = 5.dp.toPx(), center = Offset(cx, y))
            drawCircle(Color.White, radius = 2.6.dp.toPx(), center = Offset(cx, y))
        } else {
            val e = (prog - launch) / (1f - launch)
            // 外扩带阻力：强 easeOut，先猛冲后几乎停住。
            val expand = 1f - (1f - e) * (1f - e) * (1f - e)
            val ePrev = (e - 0.06f).coerceAtLeast(0f)
            val expandPrev = 1f - (1f - ePrev) * (1f - ePrev) * (1f - ePrev)
            val maxR = size.minDimension * 0.24f
            val grav = maxR * 0.72f
            val fade = (1f - e * e).coerceIn(0f, 1f)

            // 起爆闪光：一记径向白光迅速炸开又淡去，给爆炸一个"起点冲击"。
            if (e < 0.22f) {
                val fe = e / 0.22f
                val flashR = maxR * (0.28f + 0.72f * fe)
                val flashA = (1f - fe) * 0.7f
                drawCircle(
                    brush = Brush.radialGradient(
                        colors = listOf(Color.White.copy(alpha = flashA), Color.Transparent),
                        center = Offset(cx, cy),
                        radius = flashR
                    ),
                    radius = flashR,
                    center = Offset(cx, cy)
                )
            }

            for (k in 0 until spec.n) {
                val ang = k * (2f * Math.PI.toFloat() / spec.n) + spec.jitter[k]
                val ca = cos(ang); val sa = sin(ang)
                val sp = spec.speed[k]
                val r = maxR * sp * expand
                val rPrev = maxR * sp * expandPrev
                val px = cx + ca * r
                val py = cy + sa * r + grav * e * e
                val ppx = cx + ca * rPrev
                val ppy = cy + sa * rPrev + grav * ePrev * ePrev
                // 尾段闪烁：每颗相位不同，明灭错开，像真火花抖动。
                val tw = 0.7f + 0.3f * sin((e * 26f + k * 1.3f).toDouble()).toFloat()
                val a = (fade * tw).coerceIn(0f, 1f)
                // 运动拖尾（comet 尾，末段收细）。
                drawLine(
                    spec.spark.copy(alpha = a * 0.5f),
                    start = Offset(ppx, ppy), end = Offset(px, py),
                    strokeWidth = (1.4f + 0.8f * (1f - e)).dp.toPx(), cap = StrokeCap.Round
                )
                // 柔光晕 + 白热核（核心随时间冷却到火花色）。
                drawCircle(spec.spark.copy(alpha = a * 0.28f), radius = 3.6.dp.toPx(), center = Offset(px, py))
                val core = lerp(Color.White, spec.spark, (e * 1.3f).coerceAtMost(1f))
                drawCircle(core.copy(alpha = a), radius = 1.7.dp.toPx(), center = Offset(px, py))
            }
        }
    }
}
