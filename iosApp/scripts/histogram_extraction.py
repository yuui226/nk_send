"""Move the original histogram only; preserve the full remaining monitor/preview bodies."""
from thumbnail_grid_extraction import section
from transfer_card_extraction import replace_once
from photo_preview_display_extraction import wrapper, public

HEADER = '''@file:OptIn(kotlin.experimental.ExperimentalObjCRefinement::class)

package com.ztransfer.ui.screen

'''

IMAGE_ADAPTER = '''/** Reads the same sampled rows from an already decoded image, without another JPEG decode. */
@kotlin.native.HiddenFromObjC
fun calculateImageLuminanceHistogram(bitmap: ImageBitmap): LuminanceHistogram =
    calculateLuminanceHistogram(bitmap.width, bitmap.height) { y, row ->
        bitmap.readPixels(row, startX = 0, startY = y, width = row.size, height = 1,
            bufferOffset = 0, stride = row.size)
    }

'''


def extract_histogram(source):
    source = source.replace('\r\n', '\n')
    model = section(source, 'internal data class LuminanceHistogram(', '/**\n * 从已经解码的 Live View Bitmap')
    analysis = section(source, 'internal fun calculateLuminanceHistogram(', '/** 过曝斑马掩码')
    overlay = section(source, '@Composable\ninternal fun HistogramOverlay(', '@Composable\ninternal fun FramingGridOverlay(')
    mark = section(source, '@Composable\ninternal fun HistogramMark(', '/** 构图参考线')
    android = replace_once(source, model, '')
    android = replace_once(android, '/** 抽样 RGB 直方图。每通道已归一化并用 log1p 压缩尖峰，绘制层不再做统计。 */\n', '')
    mark_comment = '/** 直方图——5 根竖条，中间高两端低，经典”色阶分布”形状。 */\n'
    android = replace_once(android, mark_comment, '')
    android = replace_once(android, analysis, '''internal fun calculateLuminanceHistogram(bitmap: Bitmap): LuminanceHistogram =
    calculateLuminanceHistogram(bitmap.width, bitmap.height) { y, row ->
        bitmap.getPixels(row, 0, row.size, 0, y, row.size, 1)
    }

''')
    android = replace_once(android, overlay, '')
    android = replace_once(android, mark, '')
    model = replace_once(model, 'internal data class', '@kotlin.native.HiddenFromObjC\ndata class')
    analysis = replace_once(analysis, 'internal fun calculateLuminanceHistogram(bitmap: Bitmap)', '''@kotlin.native.HiddenFromObjC
fun calculateLuminanceHistogram(
    inputWidth: Int,
    inputHeight: Int,
    readRow: (y: Int, row: IntArray) -> Unit,
)''')
    analysis = replace_once(analysis, 'bitmap.width.coerceAtLeast(1)', 'inputWidth.coerceAtLeast(1)')
    analysis = replace_once(analysis, 'bitmap.height.coerceAtLeast(1)', 'inputHeight.coerceAtLeast(1)')
    analysis = replace_once(analysis, 'bitmap.getPixels(row, 0, width, 0, y, width, 1)', 'readRow(y, row)')
    core = HEADER + 'import kotlin.math.ceil\nimport kotlin.math.sqrt\n\n' + '/** 原Rec.709亮度抽样，256个bin按峰值线性归一化；不是RGB分通道或log压缩。 */\n' + model + analysis
    core = core.rstrip() + '\n'
    for name in ('HistogramOverlay', 'HistogramMark'):
        if name == 'HistogramOverlay':
            overlay = replace_once(overlay, '@Composable\ninternal fun '+name, '@kotlin.native.HiddenFromObjC\n@Composable\nfun '+name)
        else:
            mark = replace_once(mark, '@Composable\ninternal fun '+name, '@kotlin.native.HiddenFromObjC\n@Composable\nfun '+name)
    stroke = section(source, 'private val ToolMarkStrokeWidth', 'internal enum class ViewfinderGrid')
    stroke = replace_once(stroke, 'ToolMarkStrokeWidth', 'HistogramMarkStrokeWidth')
    mark = replace_once(mark, 'ToolMarkStrokeWidth.toPx()', 'HistogramMarkStrokeWidth.toPx()')
    ui = HEADER + '''import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.material3.LocalContentColor
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.dp

''' + stroke + IMAGE_ADAPTER + overlay + mark_comment + mark
    return android, core, ui.rstrip() + '\n'


def extract_histogram_button(source):
    source = source.replace('\r\n', '\n')
    button = section(source, '@Composable\nprivate fun PreviewHistogramButton(', '/**\n * 预览页"加入传输队列"按钮')
    android = replace_once(source, button, wrapper(button, '''SharedPreviewHistogramButton(active, onClick,
        description = { stringResource(R.string.cd_preview_histogram) })'''))
    button = public(button, 'PreviewHistogramButton', 'SharedPreviewHistogramButton')
    button = replace_once(button, '    onClick: () -> Unit,\n', '    onClick: () -> Unit,\n    description: @Composable () -> String,\n')
    button = replace_once(button, 'val description = stringResource(R.string.cd_preview_histogram)', 'val description = description()')
    shared = HEADER + '''import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.LocalContentColor
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.ztransfer.ui.theme.AppTheme

''' + button
    return android, shared.rstrip() + '\n'


def expected_histogram_oracle(source):
    """Frozen test-only Android algorithm; only its signature/type is adapted to a fake Bitmap."""
    original = section(source, 'internal fun calculateLuminanceHistogram(', '/** 过曝斑马掩码')
    original = replace_once(original, 'internal fun calculateLuminanceHistogram(bitmap: Bitmap)',
                            'private fun originalHistogram(bitmap: HistogramOracleBitmap)')
    return '''package com.ztransfer.ui.screen

import kotlin.math.ceil
import kotlin.math.sqrt

// Test-only oracle from Android 55876fa. Production must use the shared implementation.
internal fun originalHistogramOracle(width: Int, height: Int, pixel: (Int, Int) -> Int): FloatArray =
    originalHistogram(HistogramOracleBitmap(width, height, pixel)).bins

private class HistogramOracleBitmap(val width: Int, val height: Int, val pixel: (Int, Int) -> Int) {
    fun getPixels(target: IntArray, offset: Int, stride: Int, x: Int, y: Int, width: Int, height: Int) {
        for (r in 0 until height) for (c in 0 until width) {
            target[offset + r * stride + c] = pixel(x + c, y + r)
        }
    }
}

''' + original.rstrip() + '\n'
