package com.ztransfer.diagnostics

import android.content.Context
import android.util.Base64
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.URL
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter
import javax.net.ssl.HttpsURLConnection
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.json.JSONObject

/** Temporary private Debug probe delivery; no QQ credentials or sender exist in Release. */
internal object StaProbeQqSender {
    private const val CONFIG_ASSET = "sta-probe-qq.json"
    private const val MAX_REPORT_BYTES = 256 * 1024
    private const val MAX_RESPONSE_BYTES = 64 * 1024

    /** Sends exactly one file message to the locally configured owner's QQ account. */
    suspend fun send(context: Context, report: String): String = try {
        withTimeout(60_000L) { sendWithinDeadline(context, report) }
    } catch (_: TimeoutCancellationException) {
        // Our delivery deadline is a send failure, not cancellation of the completed probe.
        currentCoroutineContext().ensureActive()
        throw DeliveryException("QQ 回传超时，请先查看 QQ，日志仍可手动分享")
    }

    private suspend fun sendWithinDeadline(context: Context, report: String): String =
        withContext(Dispatchers.IO) {
            try {
                val data = report.toByteArray(Charsets.UTF_8)
                if (data.isEmpty() || data.size > MAX_REPORT_BYTES) {
                    throw DeliveryException("日志大小无效，请手动分享")
                }
                val config = try {
                    context.assets.open(CONFIG_ASSET).bufferedReader(Charsets.UTF_8).use {
                        JSONObject(it.readText())
                    }
                } catch (_: Exception) {
                    throw DeliveryException("未配置 QQ 回传，请手动分享")
                }
                val appId = config.optString("appId").trim()
                val secret = config.optString("appSecret").trim()
                val recipient = config.optString("targetOpenid").trim()
                if (appId.isEmpty() || secret.isEmpty() || !recipient.matches(Regex("[A-Za-z0-9_-]+"))) {
                    throw DeliveryException("QQ 回传配置无效，请手动分享")
                }

                val token = postJson(
                    "https://bots.qq.com/app/getAppAccessToken",
                    JSONObject().put("appId", appId).put("clientSecret", secret),
                    stage = "QQ 验证",
                ).optString("access_token").takeIf { it.isNotBlank() }
                    ?: throw DeliveryException("QQ 验证失败，请手动分享")

                val stamp = LocalDateTime.now().format(DateTimeFormatter.ofPattern("MMdd-HHmmss-SSS"))
                val uploaded = postJson(
                    "https://api.bot.qq.com/v2/users/$recipient/files",
                    JSONObject()
                        .put("file_type", 4)
                        .put("srv_send_msg", false)
                        .put("file_name", "STA-$stamp.txt")
                        .put("file_data", Base64.encodeToString(data, Base64.NO_WRAP)),
                    token = token,
                    stage = "日志上传",
                ).optString("file_info").takeIf { it.isNotBlank() }
                    ?: throw DeliveryException("日志上传失败，请手动分享")

                // Never retry this POST automatically: a lost response may still mean delivery.
                val message = postJson(
                    "https://api.bot.qq.com/v2/users/$recipient/messages",
                    JSONObject()
                        .put("msg_type", 7)
                        .put("msg_seq", 1)
                        .put("media", JSONObject().put("file_info", uploaded)),
                    token = token,
                    stage = "QQ 发送",
                )
                if (message.optString("id").isBlank()) {
                    throw DeliveryException("未确认发送，请先查看 QQ，日志仍可手动分享")
                }
                "QQ 已接收日志"
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (safe: DeliveryException) {
                throw safe
            } catch (_: Exception) {
                // Do not attach raw exceptions: request URLs and API payloads contain secrets.
                throw DeliveryException("QQ 回传未完成，请先查看 QQ，日志仍可手动分享")
            }
        }

    private suspend fun postJson(
        url: String,
        body: JSONObject,
        token: String? = null,
        stage: String,
    ): JSONObject {
        currentCoroutineContext().ensureActive()
        val connection = URL(url).openConnection() as HttpsURLConnection
        try {
            connection.requestMethod = "POST"
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 15_000
            connection.readTimeout = 15_000
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json; charset=utf-8")
            connection.setRequestProperty("User-Agent", "ZTransfer-STA-Probe/1")
            if (token != null) connection.setRequestProperty("Authorization", "QQBot $token")
            val bytes = body.toString().toByteArray(Charsets.UTF_8)
            // Streaming mode also prevents HttpURLConnection from replaying a failed POST.
            connection.setFixedLengthStreamingMode(bytes.size)
            connection.outputStream.use { it.write(bytes) }
            currentCoroutineContext().ensureActive()
            val status = connection.responseCode
            if (status !in 200..299) throw DeliveryException("$stage 失败（HTTP $status），请手动分享")
            val response = connection.inputStream.use { input ->
                val buffer = ByteArray(4096)
                val output = ByteArrayOutputStream()
                while (true) {
                    currentCoroutineContext().ensureActive()
                    val count = input.read(buffer)
                    if (count < 0) break
                    if (output.size() + count > MAX_RESPONSE_BYTES) {
                        throw DeliveryException("$stage 返回异常，请手动分享")
                    }
                    output.write(buffer, 0, count)
                }
                JSONObject(output.toString(Charsets.UTF_8.name()))
            }
            val businessCode = response.optInt("code", response.optInt("err_code", 0))
            if (businessCode != 0) {
                throw DeliveryException("$stage 失败（$businessCode），请手动分享")
            }
            return response
        } finally {
            connection.disconnect()
        }
    }

    private class DeliveryException(message: String) : IOException(message)
}
