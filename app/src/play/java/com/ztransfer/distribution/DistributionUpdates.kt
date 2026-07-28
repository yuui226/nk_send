package com.ztransfer.distribution

import android.content.Context
import androidx.compose.runtime.Composable

/**
 * Google Play 渠道不初始化、展示或携带 APK 自更新实现；版本更新完全交给 Play。
 */
object DistributionUpdates {
    fun init(context: Context) = Unit
}

@Composable
fun DistributionUpdateHost(cameraUsesWifi: Boolean) = Unit
