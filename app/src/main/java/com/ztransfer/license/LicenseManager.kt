package com.ztransfer.license

import android.annotation.SuppressLint
import android.content.Context
import android.content.SharedPreferences
import android.provider.Settings
import android.util.Base64
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.URL
import java.security.KeyFactory
import java.security.MessageDigest
import java.security.Signature
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import java.security.spec.X509EncodedKeySpec
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import javax.net.ssl.HostnameVerifier
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocketFactory
import javax.net.ssl.X509TrustManager

/**
 * 授权管理:免费/付费状态、每日免费额度、激活与静默续签。
 *
 * 通行证 = base64url(payload JSON) + "." + base64url(ECDSA P-256 签名),由服务器签发,
 * 本地用内置公钥验签 + 核对设备指纹,日常使用完全离线。协议见 docs/激活与付费设计.md。
 *
 * 传输热路径零接触:额度判定只发生在用户点击入队的瞬间(一次 SharedPreferences 读写)。
 */
object LicenseManager {

    // ==================== 部署产出的三个常量(见 server/部署指南.md)====================
    // 服务器地址列表,按序尝试。将来换 IP/上域名:在新版本里更新此列表即可。
    private val SERVERS = listOf("https://106.15.239.203:8443")
    // setup-keys.js init 输出的"App 内置公钥"(ECDSA P-256 SPKI)
    private const val PUBLIC_KEY_B64 =
        "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEqiQGFyGSVfCF2d96gr9wEQcjhOzQ1Iyxbeml+4uEYLiWDSEmf0AstKOnvg2YNIKPg25bLaY+xg5hrvLPhBks3w=="
    // setup-keys.js pin tls-cert.pem 输出的"App 内置证书指纹"(SPKI SHA-256)
    private const val CERT_PIN_B64 = "9SNNH7dEGfIVJ0bMGIKxEYTjHUAMDy3+t/+dVZzJfzA="
    // =====================================================================================

    // 免费版限制(集中定义,调整数值只改这里)
    // 传输:每天完成 25 个(完成才计数,入队/跳过不计) + 单文件 ≤400MB;
    // 监看:每天累计 3 分钟。
    const val FREE_DAILY_TRANSFER_LIMIT = 25
    const val FREE_MAX_FILE_BYTES = 400L * 1024 * 1024
    const val FREE_REMOTE_DAILY_MS = 3 * 60_000L

    private const val RENEW_INTERVAL_MS = 7 * 24 * 3600_000L
    private const val PREFS = "license"

    private lateinit var prefs: SharedPreferences
    private var fingerprint: String = ""

    private val _isPro = MutableStateFlow(false)
    val isPro: StateFlow<Boolean> get() = _isPro

    // 今日剩余免费传输数,随 recordTransferDone 即时更新;PRO 恒 Int.MAX_VALUE。
    // UI 订阅它做"临近上限"预警——提示与计数同源,在完成 +1 之后弹出而非入队时。
    private val _quotaLeft = MutableStateFlow(Int.MAX_VALUE)
    val quotaLeft: StateFlow<Int> get() = _quotaLeft

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /** 在 MainActivity.onCreate 调用一次:恢复本地状态并触发静默续签。 */
    fun init(context: Context) {
        if (::prefs.isInitialized) return
        val app = context.applicationContext
        prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        fingerprint = computeFingerprint(app)
        _isPro.value = verifyToken(prefs.getString("token", null)) != null
        _quotaLeft.value = quotaRemaining()
        scope.launch { renewIfDue() }
    }

    // ---------------------------------------------------------------- 指纹

    @SuppressLint("HardwareIds")
    private fun computeFingerprint(context: Context): String {
        val androidId = Settings.Secure.getString(
            context.contentResolver, Settings.Secure.ANDROID_ID
        ) ?: "unknown"
        val digest = MessageDigest.getInstance("SHA-256")
            .digest("$androidId:${context.packageName}".toByteArray())
        return digest.take(16).joinToString("") { "%02x".format(it) }
    }

    /** 人读设备码 ZT-XXXX-XXXX(指纹前 8 个 hex),激活页展示 + 客服换绑沟通用。 */
    fun displayCode(): String {
        val p = fingerprint.uppercase()
        return "ZT-${p.substring(0, 4)}-${p.substring(4, 8)}"
    }

    // ---------------------------------------------------------------- 通行证

    /** 验签 + 指纹核对,通过返回 payload,否则 null。任何异常一律视为无效(降级免费)。 */
    private fun verifyToken(token: String?): JSONObject? {
        if (token.isNullOrBlank()) return null
        return try {
            val parts = token.split(".")
            if (parts.size != 2) return null
            val payload = Base64.decode(parts[0], Base64.URL_SAFE or Base64.NO_WRAP)
            val sig = Base64.decode(parts[1], Base64.URL_SAFE or Base64.NO_WRAP)
            val pub = KeyFactory.getInstance("EC").generatePublic(
                X509EncodedKeySpec(Base64.decode(PUBLIC_KEY_B64, Base64.DEFAULT))
            )
            val ok = Signature.getInstance("SHA256withECDSA").run {
                initVerify(pub); update(payload); verify(sig)
            }
            if (!ok) return null
            val obj = JSONObject(String(payload, Charsets.UTF_8))
            if (obj.optInt("v") != 1 || obj.optString("fp") != fingerprint) return null
            obj
        } catch (_: Exception) {
            null
        }
    }

    private fun saveToken(token: String, code: String) {
        prefs.edit()
            .putString("token", token)
            .putString("code", code)
            .putLong("last_renew", System.currentTimeMillis())
            .apply()
        _isPro.value = true
        _quotaLeft.value = quotaRemaining()
    }

    /** 清除本地授权(测试按钮/被吊销)。不动服务器绑定,重新输入激活码即可恢复。 */
    fun revertToFree() {
        prefs.edit().remove("token").remove("code").remove("last_renew").apply()
        _isPro.value = false
        _quotaLeft.value = quotaRemaining()
    }

    // ---------------------------------------------------------------- 免费额度
    // 两本"日账":传输完成数(q_*)与监看已用毫秒(r_*)。值只在 date 键等于今天时有效,
    // 跨天读到旧日期即视为 0,无须任何定时清零。计数规则:
    // 传输只在【真正传完】时 +1——失败/取消/已存在跳过都不计;监看每天累计,退出即停。

    private fun today(): String =
        SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date())

    private fun transfersDoneToday(): Int =
        if (prefs.getString("q_date", "") == today()) prefs.getInt("q_used", 0) else 0

    private fun remoteUsedTodayMs(): Long =
        if (prefs.getString("r_date", "") == today()) prefs.getLong("r_used", 0L) else 0L

    /** 今日剩余免费传输数;PRO 恒为 Int.MAX_VALUE。也以 [quotaLeft] 流的形式对 UI 暴露。 */
    fun quotaRemaining(): Int =
        if (_isPro.value) Int.MAX_VALUE
        else (FREE_DAILY_TRANSFER_LIMIT - transfersDoneToday()).coerceAtLeast(0)

    /** 免费版今日完成数是否已达上限(传输队列每个任务开始前检查)。PRO 恒 false。 */
    fun transferLimitReached(): Boolean =
        !_isPro.value && transfersDoneToday() >= FREE_DAILY_TRANSFER_LIMIT

    /**
     * 免费版单文件大小是否超限(传输队列每个任务开始前检查)。PRO 恒 false。
     * >4GB 对象的 size 是 0xFFFFFFFF 哨兵,数值上必然超限——恰好一并拦住,无需特判。
     */
    fun freeSizeLimitExceeded(sizeBytes: Long): Boolean =
        !_isPro.value && sizeBytes > FREE_MAX_FILE_BYTES

    /** 传输完成计数 +1,并推送最新剩余到 [quotaLeft](触发 UI 的临近上限预警)。PRO 空操作。 */
    fun recordTransferDone() {
        if (_isPro.value) return
        prefs.edit().putString("q_date", today()).putInt("q_used", transfersDoneToday() + 1).apply()
        _quotaLeft.value = quotaRemaining()
    }

    /** 免费版今日剩余监看时长(毫秒,每天累计 [FREE_REMOTE_DAILY_MS]);PRO 恒为 Long.MAX_VALUE。 */
    fun remoteTimeLeftMs(): Long =
        if (_isPro.value) Long.MAX_VALUE
        else (FREE_REMOTE_DAILY_MS - remoteUsedTodayMs()).coerceAtLeast(0L)

    /** 累计已用监看时长(监看页计时每秒记账,退出页面即停止;跨天自动换日重记)。PRO 空操作。 */
    fun consumeRemoteTime(ms: Long) {
        if (_isPro.value) return
        prefs.edit().putString("r_date", today()).putLong("r_used", remoteUsedTodayMs() + ms).apply()
    }

    // ---------------------------------------------------------------- 激活/续签

    sealed class ActivationResult {
        object Success : ActivationResult()
        /** 所有服务器地址都联不上:提示检查网络/更新新版本。 */
        object Unreachable : ActivationResult()
        /** 服务器明确拒绝,code 为协议错误码(CODE_NOT_FOUND / SLOTS_FULL / ...)。 */
        data class Rejected(val code: String) : ActivationResult()
    }

    suspend fun activate(rawCode: String, appVersion: String): ActivationResult =
        withContext(Dispatchers.IO) {
            val code = rawCode.trim().uppercase()
            val resp = post("/v1/activate", JSONObject().apply {
                put("code", code)
                put("fp", fingerprint)
                put("model", "${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}".trim())
                put("app_ver", appVersion)
            }) ?: return@withContext ActivationResult.Unreachable

            val token = resp.optString("token")
            if (resp.optBoolean("ok") && verifyToken(token) != null) {
                saveToken(token, code)
                ActivationResult.Success
            } else {
                ActivationResult.Rejected(resp.optString("err", "BAD_RESPONSE"))
            }
        }

    /**
     * 静默续签:PRO 且距上次成功 ≥ 7 天且有网时换新通行证。
     * 只有服务器明确吊销/解绑才降级;网络失败保持现状(离线不惩罚)。
     */
    private suspend fun renewIfDue() {
        if (!_isPro.value) return
        val last = prefs.getLong("last_renew", 0L)
        if (System.currentTimeMillis() - last < RENEW_INTERVAL_MS) return
        val code = prefs.getString("code", null) ?: return

        val resp = post("/v1/renew", JSONObject().apply {
            put("code", code)
            put("fp", fingerprint)
        }) ?: return   // 联不上:保持现状

        val token = resp.optString("token")
        if (resp.optBoolean("ok") && verifyToken(token) != null) {
            saveToken(token, code)
        } else when (resp.optString("err")) {
            "CODE_REVOKED", "NOT_BOUND" -> revertToFree()
            else -> Unit   // 未知错误按网络异常处理,不降级
        }
    }

    // ---------------------------------------------------------------- 网络

    /** 依次尝试所有服务器地址;全部失败返回 null。业务成败由响应 JSON 的 ok/err 表达。 */
    private fun post(path: String, body: JSONObject): JSONObject? {
        for (base in SERVERS) {
            try {
                val conn = URL(base + path).openConnection() as HttpsURLConnection
                conn.sslSocketFactory = pinnedSocketFactory
                // 证书本身已由 pin 唯一确认,无需再校验主机名(自签证书对裸 IP 签发)
                conn.hostnameVerifier = HostnameVerifier { _, _ -> true }
                conn.requestMethod = "POST"
                conn.doOutput = true
                conn.connectTimeout = 8000
                conn.readTimeout = 8000
                conn.setRequestProperty("Content-Type", "application/json")
                conn.outputStream.use { it.write(body.toString().toByteArray()) }
                val text = (if (conn.responseCode < 400) conn.inputStream else conn.errorStream)
                    .bufferedReader().use { it.readText() }
                return JSONObject(text)
            } catch (_: Exception) {
                // 换下一个地址
            }
        }
        return null
    }

    /** 只信任 pin 匹配的服务器证书(自签证书 + IP 直连场景的标准做法)。 */
    private val pinnedSocketFactory: SSLSocketFactory by lazy {
        val tm = object : X509TrustManager {
            override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) {
                val spki = chain[0].publicKey.encoded
                val pin = Base64.encodeToString(
                    MessageDigest.getInstance("SHA-256").digest(spki), Base64.NO_WRAP
                )
                if (pin != CERT_PIN_B64) throw CertificateException("certificate pin mismatch")
            }

            override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) =
                throw CertificateException("client certs not supported")

            override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
        }
        SSLContext.getInstance("TLS").apply { init(null, arrayOf(tm), null) }.socketFactory
    }
}
