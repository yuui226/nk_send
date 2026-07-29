package com.ztransfer.ui.screen

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.sp
import androidx.compose.ui.unit.dp

/** 监看参数卡原有的左上字段名；AUTO 式贴角外观由 [ControlTileCornerBadge] 负责。 */
@Composable
internal fun ControlTileFieldLabel(
    text: String,
    color: Color,
    modifier: Modifier = Modifier,
) {
    Text(
        text = text,
        color = color,
        fontSize = 10.sp,
        fontWeight = FontWeight.SemiBold,
        maxLines = 1,
        modifier = modifier,
    )
}

/**
 * 监看 ISO 的 AUTO 开关与设置拨轮共用的贴角胶囊外观。这里只画形状，不安装点击手势；
 * 交互仍由外层卡片负责，因此设置拨轮的左上角标不会形成触摸死区。
 */
@Composable
internal fun ControlTileCornerBadge(
    text: String,
    textColor: Color,
    backgroundColor: Color,
    borderColor: Color,
    shape: Shape,
    modifier: Modifier = Modifier,
    fontSize: TextUnit = 9.sp,
    borderWidth: Dp = 0.75.dp,
    contentPadding: PaddingValues = PaddingValues(horizontal = 6.dp),
) {
    Box(
        modifier = modifier
            .clip(shape)
            .background(backgroundColor)
            .border(borderWidth, borderColor, shape),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = text,
            color = textColor,
            fontSize = fontSize,
            lineHeight = (fontSize.value + 1f).sp,
            fontWeight = FontWeight.Medium,
            maxLines = 1,
            modifier = Modifier.padding(contentPadding),
        )
    }
}
