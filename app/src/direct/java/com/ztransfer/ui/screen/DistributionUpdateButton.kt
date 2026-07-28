package com.ztransfer.ui.screen

import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.ztransfer.R
import com.ztransfer.license.LicenseManager
import com.ztransfer.ui.theme.AppTheme
import com.ztransfer.update.AppUpdateManager
import kotlinx.coroutines.launch

/** 国内直装版设置页的手动更新按钮；Play source set 提供空实现。 */
@Composable
internal fun DistributionUpdateButton(
    cameraUsesWifi: Boolean,
    onHint: (String) -> Unit
) {
    var checkingUpdate by remember { mutableStateOf(false) }
    val updateScope = rememberCoroutineScope()
    val latestHint = stringResource(R.string.update_latest)
    val checkFailedHint = stringResource(R.string.update_check_failed)
    val internetRequiredHint = stringResource(R.string.err_purchase_no_network)
    val colors = AppTheme.colors

    GlassButton(
        onClick = {
            if (cameraUsesWifi) {
                onHint(internetRequiredHint)
            } else if (!checkingUpdate) {
                checkingUpdate = true
                updateScope.launch {
                    when (AppUpdateManager.check(force = true)) {
                        is LicenseManager.UpdateResult.Available -> Unit
                        LicenseManager.UpdateResult.UpToDate -> onHint(latestHint)
                        LicenseManager.UpdateResult.Unreachable -> onHint(checkFailedHint)
                    }
                    checkingUpdate = false
                }
            }
        },
        shape = RoundedCornerShape(14.dp),
        contentPadding = PaddingValues(horizontal = 14.dp),
        modifier = Modifier.height(28.dp)
    ) {
        Text(
            stringResource(if (checkingUpdate) R.string.checking_update else R.string.check_update),
            style = MaterialTheme.typography.labelMedium,
            color = colors.onBackground
        )
    }
    Spacer(Modifier.width(8.dp))
}
