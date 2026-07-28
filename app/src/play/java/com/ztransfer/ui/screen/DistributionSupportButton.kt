package com.ztransfer.ui.screen

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.ztransfer.R
import com.ztransfer.ui.theme.AppTheme

private const val PRIVACY_POLICY_URL = "https://www.ztransfer.top/privacy.html"

/** Play 版在应用内直接提供隐私政策入口。 */
@Composable
internal fun DistributionSupportButton(onHint: (String) -> Unit) {
    val context = LocalContext.current
    val openFailedHint = stringResource(R.string.privacy_open_failed)
    val colors = AppTheme.colors

    GlassButton(
        onClick = {
            runCatching {
                context.startActivity(
                    Intent(Intent.ACTION_VIEW, Uri.parse(PRIVACY_POLICY_URL))
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
            }.onFailure { onHint(openFailedHint) }
        },
        shape = RoundedCornerShape(14.dp),
        contentPadding = PaddingValues(horizontal = 14.dp),
        modifier = Modifier.height(28.dp)
    ) {
        Text(
            stringResource(R.string.privacy_policy),
            style = MaterialTheme.typography.labelMedium,
            color = colors.onBackground
        )
    }
}
