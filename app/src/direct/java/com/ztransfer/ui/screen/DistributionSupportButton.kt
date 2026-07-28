package com.ztransfer.ui.screen

import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.unit.dp
import com.ztransfer.R
import com.ztransfer.ui.theme.AppTheme

private const val QQ_NUMBER = "953000922"

/** 国内直装版保持原有的 QQ 反馈入口和交互。 */
@Composable
internal fun DistributionSupportButton(onHint: (String) -> Unit) {
    val clipboard = LocalClipboardManager.current
    val copiedHint = stringResource(R.string.feedback_qq_copied, QQ_NUMBER)
    val colors = AppTheme.colors

    GlassButton(
        onClick = {
            clipboard.setText(AnnotatedString(QQ_NUMBER))
            onHint(copiedHint)
        },
        shape = RoundedCornerShape(14.dp),
        contentPadding = PaddingValues(horizontal = 14.dp),
        modifier = Modifier.height(28.dp)
    ) {
        Text(
            stringResource(R.string.feedback),
            style = MaterialTheme.typography.labelMedium,
            color = colors.onBackground
        )
    }
}
