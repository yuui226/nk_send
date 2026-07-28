package com.ztransfer.distribution

import android.content.Context
import androidx.compose.runtime.Composable
import com.ztransfer.update.AppUpdateHost
import com.ztransfer.update.AppUpdateManager

/**
 * 国内直装渠道的自更新入口。实现位于 direct source set，确保 Play 产物不包含 APK
 * 下载、校验、安装器或未知来源授权相关代码。
 */
object DistributionUpdates {
    fun init(context: Context) {
        AppUpdateManager.init(context)
    }
}

@Composable
fun DistributionUpdateHost(cameraUsesWifi: Boolean) {
    AppUpdateHost(cameraUsesWifi = cameraUsesWifi)
}
