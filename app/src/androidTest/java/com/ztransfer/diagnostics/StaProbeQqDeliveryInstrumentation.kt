package com.ztransfer.diagnostics

import android.app.Activity
import android.app.Instrumentation
import android.os.Build
import android.os.Bundle
import kotlinx.coroutines.runBlocking

/** Explicit emulator-only smoke test of the same direct QQ delivery used by the Debug probe. */
class StaProbeQqDeliveryInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        start()
    }

    override fun onStart() {
        val result = Bundle()
        try {
            check(Build.HARDWARE in setOf("ranchu", "goldfish") &&
                (Build.FINGERPRINT.contains("generic") || Build.MODEL.contains("sdk", ignoreCase = true))) {
                "QQ delivery smoke test requires an emulator"
            }
            val delivery = runBlocking {
                StaProbeQqSender.send(
                    targetContext,
                    "STA探测回传测试：Android直连QQ通道验证，不含相机数据。\n" +
                        "这是一份连通性测试文件，不是相机探测结果。\n",
                )
            }
            result.putString("result", "PASS: $delivery")
            finish(Activity.RESULT_OK, result)
        } catch (error: Exception) {
            // The sender exposes only sanitized errors; never dump causes or request data.
            result.putString("result", "FAIL: ${error.javaClass.simpleName}: ${error.message.orEmpty().take(180)}")
            finish(Activity.RESULT_CANCELED, result)
        }
    }
}
