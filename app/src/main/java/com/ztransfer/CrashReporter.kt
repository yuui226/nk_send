package com.ztransfer

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.util.Log
import android.widget.Toast
import java.io.PrintWriter
import java.io.StringWriter

/** 真机无需连接电脑：保存上次未捕获异常，下次启动自动复制到剪贴板。 */
object CrashReporter {
    private const val PREFS = "crash_reporter"
    private const val KEY_LAST_CRASH = "last_crash"
    private const val TAG = "ZTransfer.Crash"

    fun install(context: Context) {
        val app = context.applicationContext
        val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        prefs.getString(KEY_LAST_CRASH, null)?.let { report ->
            Log.e(TAG, report)
            runCatching {
                val clipboard = app.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                clipboard.setPrimaryClip(ClipData.newPlainText("ZTransfer crash", report))
                Toast.makeText(app, "上次闪退信息已复制，请直接粘贴发给开发者", Toast.LENGTH_LONG).show()
            }
            prefs.edit().remove(KEY_LAST_CRASH).apply()
        }

        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            val trace = StringWriter().also { throwable.printStackTrace(PrintWriter(it)) }.toString()
            val report = buildString {
                appendLine("ZTransfer ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})")
                appendLine("Android ${Build.VERSION.RELEASE} SDK ${Build.VERSION.SDK_INT}")
                appendLine("Device ${Build.MANUFACTURER} ${Build.MODEL}")
                appendLine("Thread ${thread.name}")
                append(trace.take(48_000))
            }
            runCatching { prefs.edit().putString(KEY_LAST_CRASH, report).commit() }
            previous?.uncaughtException(thread, throwable)
        }
    }
}
