package com.ztransfer.ui.screen

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
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
import kotlin.math.PI
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
 * 渲染当前所有活跃烟花（各自全屏 Canvas、不拦截触摸）。放在页面最上层,不加暗幕,直接放。
 */
@Composable
fun FireworksOverlay(state: FireworksState) {
    state.active.forEach { id ->
        key(id) { Firework(seed = id, onFinished = { state.active.remove(id) }) }
    }
}

/**
 * 一发烟花的形态,由 seed 确定性生成。整发单色成调（[base]），粒子各自向白偏移 [shade]
 * 拉出明暗层次——比多色乱撒更"成套"。每颗主火花有独立的速度 [speed]、角度抖动 [jitter]、
 * 寿命 [life]（错落熄灭,不齐刷刷消失）与重量 [weight]（下垂各异）；[gSpeed]/[gPhase]
 * 是另一组更细碎的"星尘"参数。[sway] 为上升段的横向轻摆（-1..1）。
 */
private class FireworkSpec(
    val x: Float, val y: Float,
    val base: Color, val n: Int, val m: Int,
    val speed: FloatArray, val jitter: FloatArray,
    val life: FloatArray, val weight: FloatArray, val shade: FloatArray,
    val gSpeed: FloatArray, val gPhase: FloatArray,
    val sway: Float
)

/**
 * 单发烟花（点一次放一发，可连点并发）。分两段：
 * ①上升：渐隐拖尾带一点横向轻摆冲到爆点，临近顶端减速。
 * ②爆炸：一记小而柔的双色闪做"起点"；主火花四次方缓出外扩
 *   （空气阻力感）、按各自重量下垂、按各自寿命错落熄灭，尾段渐起闪烁；其间混一层
 *   更小更慢的星尘,断续明灭、缓缓飘落,主体谢幕后仍留一点余韵。
 * 纯 Canvas 逐帧绘制（只读 t.value → 只重绘不重组）、不拦截触摸；[onFinished] 播完回调，
 * 父层据此把本发从活跃列表移除。
 */
@Composable
private fun Firework(seed: Int, onFinished: () -> Unit) {
    val t = remember { Animatable(0f) }
    val done by rememberUpdatedState(onFinished)
    LaunchedEffect(Unit) {
        t.animateTo(1f, tween(2000, easing = LinearEasing))
        done()
    }
    val spec = remember(seed) {
        // 确定性伪随机（xorshift 风格哈希）：同一 seed 稳定，不同 seed 各异，免 Random。
        fun rnd(a: Int): Float {
            var h = (seed * 374761393) xor (a * 668265263)
            h = (h xor (h ushr 13)) * 1274126177
            return ((h xor (h ushr 16)) and 0x7fffffff) / 2147483647f
        }
        // 精选低饱和"珠光"色：亮暗背景都立得住,又不刺眼。
        val palette = listOf(
            Color(0xFFE8C468), // 香槟金
            Color(0xFFE58FA8), // 蔷薇粉
            Color(0xFF6FBFC7), // 青瓷
            Color(0xFF9D8FDB), // 雾紫
            Color(0xFF7FB7E3), // 天青
            Color(0xFF86C69A)  // 豆青
        )
        val n = 36
        val m = 18
        val gap = 2f * PI.toFloat() / n
        FireworkSpec(
            x = 0.18f + rnd(1) * 0.64f,
            y = 0.16f + rnd(2) * 0.30f,
            base = palette[(seed % palette.size + palette.size) % palette.size],
            n = n, m = m,
            // 速度分布 0.55..1.0：部分火花飞得更远，爆团有厚度而非一个薄圆环。
            speed = FloatArray(n) { 0.55f + rnd(it * 2 + 10) * 0.45f },
            jitter = FloatArray(n) { (rnd(it * 2 + 11) - 0.5f) * gap },
            life = FloatArray(n) { 0.7f + rnd(it * 3 + 12) * 0.3f },
            weight = FloatArray(n) { 0.75f + rnd(it * 3 + 13) * 0.5f },
            shade = FloatArray(n) { rnd(it * 3 + 14) * 0.35f },
            gSpeed = FloatArray(m) { 0.35f + rnd(it * 5 + 40) * 0.4f },
            gPhase = FloatArray(m) { rnd(it * 5 + 41) * 2f * PI.toFloat() },
            sway = (rnd(3) - 0.5f) * 2f
        )
    }
    Canvas(modifier = Modifier.fillMaxSize()) {
        val prog = t.value
        val launch = 0.2f
        val cx = spec.x * size.width
        val cy = spec.y * size.height
        if (prog < launch) {
            // 上升：曲线拖尾——沿真实弧线轨迹回采多点连成折线,随横摆弯曲,逐段收细渐隐;
            // 头部柔光白热,临近顶端减速、拖尾收短。
            val l = prog / launch
            val le = 1f - (1f - l) * (1f - l)
            val sway = spec.sway * 8.dp.toPx()
            fun riseAt(f: Float): Offset {
                val fe = 1f - (1f - f) * (1f - f)
                return Offset(
                    cx + sin(fe * PI.toFloat()) * sway,
                    size.height + (cy - size.height) * fe
                )
            }
            val head = riseAt(l)
            val span = 0.05f + 0.22f * (1f - le)
            val segs = 6
            var prev = head
            for (i in 1..segs) {
                val p = riseAt((l - span * i / segs).coerceAtLeast(0f))
                val fadeSeg = 1f - (i - 0.5f) / segs
                drawLine(
                    spec.base.copy(alpha = 0.5f * fadeSeg),
                    start = prev, end = p,
                    strokeWidth = 2f.dp.toPx() * (0.35f + 0.65f * fadeSeg),
                    cap = StrokeCap.Round
                )
                prev = p
            }
            drawCircle(spec.base.copy(alpha = 0.25f), radius = 4.dp.toPx(), center = head)
            drawCircle(Color.White.copy(alpha = 0.95f), radius = 2.2.dp.toPx(), center = head)
        } else {
            val e = (prog - launch) / (1f - launch)
            // 外扩带阻力：四次方缓出，先猛冲后轻轻停住。
            val q = 1f - e
            val expand = 1f - q * q * q * q
            val maxR = size.minDimension * 0.22f
            val grav = maxR * 0.6f

            // 起爆闪：小而柔的白→主色双层渐变,一闪即隐,克制不糊屏。
            if (e < 0.18f) {
                val fe = e / 0.18f
                val flashR = maxR * (0.2f + 0.5f * fe)
                drawCircle(
                    brush = Brush.radialGradient(
                        colors = listOf(
                            Color.White.copy(alpha = (1f - fe) * 0.5f),
                            spec.base.copy(alpha = (1f - fe) * 0.18f),
                            Color.Transparent
                        ),
                        center = Offset(cx, cy),
                        radius = flashR
                    ),
                    radius = flashR,
                    center = Offset(cx, cy)
                )
            }
            // 主火花：单色调内向白分层,细笔触,各自寿命/重量,错落熄灭。
            for (k in 0 until spec.n) {
                val pe = (e / spec.life[k]).coerceAtMost(1f)
                if (pe >= 1f) continue
                val ang = k * (2f * PI.toFloat() / spec.n) + spec.jitter[k]
                val ca = cos(ang); val sa = sin(ang)
                val sp = spec.speed[k]
                val r = maxR * sp * expand
                val fall = grav * spec.weight[k]
                val px = cx + ca * r
                val py = cy + sa * r + fall * e * e
                val tint = lerp(spec.base, Color.White, spec.shade[k])
                // 前段亮度稳定,尾段闪烁渐强,像火星将熄时的抖动。
                val flick = 1f - (0.45f * pe) * (0.5f + 0.5f * sin(e * 24f + k * 1.7f))
                val a = ((1f - pe * pe) * flick).coerceIn(0f, 1f)
                // 曲线 comet 尾：沿真实轨迹（外扩+重力）回采 3 段折线,随下坠弯曲、逐段收细渐隐。
                var tx = px; var ty = py
                val baseW = (0.8f + 0.7f * (1f - e)).dp.toPx()
                for (s in 1..3) {
                    val es = (e - 0.035f * s).coerceAtLeast(0f)
                    val qs = 1f - es
                    val rs = maxR * sp * (1f - qs * qs * qs * qs)
                    val sx = cx + ca * rs
                    val sy = cy + sa * rs + fall * es * es
                    val fadeSeg = 1f - (s - 0.5f) / 3f
                    drawLine(
                        tint.copy(alpha = a * 0.4f * fadeSeg),
                        start = Offset(tx, ty), end = Offset(sx, sy),
                        strokeWidth = baseW * (0.35f + 0.65f * fadeSeg), cap = StrokeCap.Round
                    )
                    tx = sx; ty = sy
                }
                // 柔光晕 + 白热核（核心随时间冷却回主色调）。
                drawCircle(tint.copy(alpha = a * 0.18f), radius = 3.dp.toPx(), center = Offset(px, py))
                val core = lerp(Color.White, tint, (pe * 1.4f).coerceAtMost(1f))
                drawCircle(core.copy(alpha = a), radius = 1.3.dp.toPx(), center = Offset(px, py))
            }

            // 星尘：更小更慢的一层,断续明灭、缓缓飘落,主体谢幕后留一点余韵。
            for (k in 0 until spec.m) {
                val ang = k * (2f * PI.toFloat() / spec.m) + spec.gPhase[k]
                val r = maxR * spec.gSpeed[k] * expand
                val px = cx + cos(ang) * r
                val py = cy + sin(ang) * r + grav * 0.45f * e * e + maxR * 0.2f * e
                // 半波整流的闪烁：亮—灭—亮,相位各异。
                val tw = sin(e * 32f + k * 2.3f + spec.gPhase[k]).coerceAtLeast(0f)
                val a = ((1f - e) * tw).coerceIn(0f, 1f)
                if (a > 0.02f) {
                    val c = lerp(spec.base, Color.White, 0.55f)
                    drawCircle(c.copy(alpha = a * 0.9f), radius = 0.9.dp.toPx(), center = Offset(px, py))
                }
            }
        }
    }
}
