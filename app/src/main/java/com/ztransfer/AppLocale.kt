package com.ztransfer

import android.content.Context
import android.content.res.Configuration
import java.util.Locale

/**
 * 应用内语言切换。偏好存 SharedPreferences("ztransfer") 的 "app_language",
 * 值为 BCP-47 标签("en" / "zh-Hans" / "zh-Hant")或 [SYSTEM]（跟随系统）。
 * 所有取用户可见文案的 Context（Activity 基座、ViewModel 错误文案、服务通知）
 * 都先经 [wrap] 包装，保证界面、错误信息与通知语言一致。
 */
object AppLocale {
    const val PREF_KEY = "app_language"
    const val SYSTEM = "system"

    fun wrap(base: Context): Context {
        val tag = base.getSharedPreferences("ztransfer", Context.MODE_PRIVATE)
            .getString(PREF_KEY, SYSTEM) ?: SYSTEM
        if (tag == SYSTEM) return base
        // 不动 Locale.setDefault：它是进程级全局且切回"跟随系统"后无法恢复（粘滞），
        // 而本应用没有任何读 Locale.getDefault() 的代码——资源本地化靠配置上下文即可。
        val locale = Locale.forLanguageTag(tag)
        val config = Configuration(base.resources.configuration)
        config.setLocale(locale)
        return base.createConfigurationContext(config)
    }
}
