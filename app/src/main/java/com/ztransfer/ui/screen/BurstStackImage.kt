package com.ztransfer.ui.screen

import android.graphics.BitmapShader
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Shader
import androidx.compose.foundation.layout.Spacer
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.unit.Dp
import kotlin.math.roundToInt

/** Draw the rounded image itself with antialiasing, including the stack's rotated edges. */
@Composable
internal fun BurstStackImage(
    image: ImageBitmap,
    cornerRadius: Dp,
    opacity: State<Float>,
    modifier: Modifier = Modifier,
) {
    Spacer(modifier.drawWithCache {
        // Reuse the decoded bitmap. Shader, crop matrix and paint survive scrolling/fade frames;
        // no copied bitmap, hard edge clip or intermediate offscreen texture is needed.
        val shader = BitmapShader(image.asAndroidBitmap(), Shader.TileMode.CLAMP, Shader.TileMode.CLAMP)
        val scale = maxOf(size.width / image.width, size.height / image.height)
        shader.setLocalMatrix(Matrix().apply {
            setScale(scale, scale)
            postTranslate(
                (size.width - image.width * scale) / 2f,
                (size.height - image.height * scale) / 2f,
            )
        })
        val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG).apply {
            this.shader = shader
        }
        val radius = cornerRadius.toPx().coerceIn(0f, size.minDimension / 2f)
        onDrawBehind {
            // Only the image fades; the existing placeholder and border remain steady.
            paint.alpha = (opacity.value.coerceIn(0f, 1f) * 255).roundToInt()
            drawIntoCanvas { canvas ->
                canvas.nativeCanvas.drawRoundRect(
                    0f, 0f, size.width, size.height, radius, radius, paint,
                )
            }
        }
    })
}
