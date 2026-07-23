package com.ztransfer.license

import android.annotation.SuppressLint
import android.content.Context
import android.content.SharedPreferences
import android.provider.Settings
import android.util.Base64
import com.ztransfer.BuildConfig
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.URLEncoder
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

    // 软续签周期:有网时每天尝试换一张新通行证(顺带把服务器的"顶替/吊销"同步下来)。
    // 硬过期由服务器写进通行证的 exp(见 verifyToken);到期且续不上就降级。
    private const val SOFT_RENEW_INTERVAL_MS = 24 * 3600_000L
    private const val PREFS = "license"

    private lateinit var prefs: SharedPreferences
    private var fingerprint: String = ""

    private val _isPro = MutableStateFlow(false)
    val isPro: StateFlow<Boolean> get() = _isPro

    // 曾是高级版、通行证已过期且续签时联不上网 → 提示用户"连网续期"(连上重开即自动恢复)。
    private val _renewalNeeded = MutableStateFlow(false)
    val renewalNeeded: StateFlow<Boolean> get() = _renewalNeeded

    // 订阅到期:降级时本地的码一并清掉,单看"没有码"分不清【从没买过】和【买过但到期】。
    // 故另存一位,让首页能说"已到期,续费继续使用";拿到新通行证(saveToken)即清除。
    private val _subExpired = MutableStateFlow(false)
    val subExpired: StateFlow<Boolean> get() = _subExpired

    // 今日剩余免费传输数,随 recordTransferDone 即时更新;PRO 恒 Int.MAX_VALUE。
    // UI 订阅它做"临近上限"预警——提示与计数同源,在完成 +1 之后弹出而非入队时。
    private val _quotaLeft = MutableStateFlow(Int.MAX_VALUE)
    val quotaLeft: StateFlow<Int> get() = _quotaLeft

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /** 在 MainActivity.onCreate 调用一次:恢复本地状态,并静默续签 + 刷新定价。 */
    fun init(context: Context) {
        if (::prefs.isInitialized) return
        val app = context.applicationContext
        prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        fingerprint = computeFingerprint(app)
        _isPro.value = verifyToken(prefs.getString("token", null)) != null
        _subExpired.value = prefs.getBoolean("sub_expired", false)
        _quotaLeft.value = quotaRemaining()
        loadCachedPricing()
        scope.launch { renewIfDue() }
        scope.launch { fetchPricing(PRICE_REFRESH_MS) }
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

    /** 仅验签 + 指纹核对(不查过期),通过返回 payload。续签判定要读 exp,故单拆出来。 */
    private fun verifySig(token: String?): JSONObject? {
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

    /** 见过的最大服务器时间(秒);当作"现在"的下界,防本地时钟往回调续命。 */
    private fun seenTimeSec(): Long =
        maxOf(System.currentTimeMillis() / 1000, prefs.getLong("seen_time", 0L))

    /**
     * 验签 + 指纹 + 硬过期核对,通过返回 payload,否则 null(降级免费)。
     * 过期判定用 max(系统时间, 见过的最大服务器时间),把时钟回拨挡在门外。
     */
    private fun verifyToken(token: String?): JSONObject? {
        val obj = verifySig(token) ?: return null
        val exp = obj.optLong("exp", 0L)
        if (exp > 0L && seenTimeSec() >= exp) return null
        return obj
    }

    /**
     * 通行证里的订阅到期时刻(Unix 秒);0 = 永久有效(手动发的码)或本地无有效通行证。
     * 读 sub 不读 exp:exp 是 7 天滚动的通行证寿命,每次续签都往后挪,跟订阅到期日无关。
     * 用 verifySig 而非 verifyToken——到期当天通行证自身也过期了,仍要能把日期说给用户听。
     */
    fun subExpiresAtSec(): Long =
        verifySig(prefs.getString("token", null))?.optLong("sub", 0L) ?: 0L

    private fun saveToken(token: String, code: String) {
        val iat = verifySig(token)?.optLong("iat", 0L) ?: 0L
        prefs.edit()
            .putString("token", token)
            .putString("code", code)
            .putLong("last_renew", System.currentTimeMillis())
            .putLong("seen_time", maxOf(prefs.getLong("seen_time", 0L), iat))  // 单调递增,防回拨
            .remove("sub_expired")
            .apply()
        _isPro.value = true
        _renewalNeeded.value = false
        _subExpired.value = false
        _quotaLeft.value = quotaRemaining()
    }

    /** 清除本地授权(测试按钮/被吊销)。不动服务器绑定,重新输入激活码即可恢复。 */
    fun revertToFree() {
        prefs.edit().remove("token").remove("code").remove("last_renew")
            .remove("pending_order")   // 上一轮购买的残留单号,降级后已无意义
            .remove("pending_order_product")
            .remove("sub_expired")
            .apply()
        _isPro.value = false
        _renewalNeeded.value = false
        _subExpired.value = false
        _quotaLeft.value = quotaRemaining()
    }

    /** 订阅到期降级:清本地授权,但留一位标记,好让首页提示续费而不是当他没买过。 */
    private fun markSubExpired() {
        revertToFree()
        prefs.edit().putBoolean("sub_expired", true).apply()
        _subExpired.value = true
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
        /** 服务器明确拒绝,code 为协议错误码(CODE_NOT_FOUND / CODE_REVOKED / RATE_LIMITED / ...)。 */
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
     * 静默续签:通行证已过期、或距上次成功 ≥ 1 天时,有网就换新证。
     * 过期后即便本地已降级(_isPro=false)也照样尝试——只要还留着码,能续上就自动恢复 PRO。
     * 只有服务器明确吊销/解绑(被顶替)才降级并清除;网络失败保持现状(离线不惩罚)。
     */
    private suspend fun renewIfDue() {
        val code = prefs.getString("code", null) ?: return
        val obj = verifySig(prefs.getString("token", null))
        val exp = obj?.optLong("exp", 0L) ?: 0L
        val expired = exp in 1..seenTimeSec()
        val softDue = System.currentTimeMillis() - prefs.getLong("last_renew", 0L) >= SOFT_RENEW_INTERVAL_MS
        if (!expired && !softDue) return

        val resp = post("/v1/renew", JSONObject().apply {
            put("code", code)
            put("fp", fingerprint)
        })
        if (resp == null) {
            // 联不上:未过期则继续用(离线不惩罚);已过期(满 7 天仍无网)则降级并提示连网续期
            if (expired) {
                _isPro.value = false
                _quotaLeft.value = quotaRemaining()
                _renewalNeeded.value = true
            }
            return
        }
        val token = resp.optString("token")
        if (resp.optBoolean("ok") && verifyToken(token) != null) {
            saveToken(token, code)                        // 内部置 _isPro=true、清 renewalNeeded、滚动 7 天有效期
        } else when (resp.optString("err")) {
            "CODE_REVOKED", "NOT_BOUND" -> revertToFree()  // 被吊销/顶替:降级并清 flag
            "CODE_EXPIRED" -> markSubExpired()             // 订阅到期:降级,并记住他是"过期"而非"没买过"
            else -> Unit   // 未知错误按网络异常处理,不降级
        }
    }

    // ---------------------------------------------------------------- 恢复 / 查看码

    sealed class RestoreResult {
        object Success : RestoreResult()
        /** 服务器上没有本机的有效授权(从未购买、或已被新设备顶替)。 */
        object NotFound : RestoreResult()
        object Unreachable : RestoreResult()
    }

    /**
     * 按设备指纹恢复授权(重装后本地没码时,用户在解锁弹窗主动点"恢复")。
     * 仅当本机仍是该码当前绑定设备才成功;被顶替过的旧设备会得到 NotFound。
     */
    suspend fun restorePurchase(): RestoreResult = withContext(Dispatchers.IO) {
        val resp = post("/v1/restore", JSONObject().put("fp", fingerprint))
            ?: return@withContext RestoreResult.Unreachable
        val token = resp.optString("token")
        val code = resp.optString("code")
        if (resp.optBoolean("ok") && code.isNotEmpty() && verifyToken(token) != null) {
            saveToken(token, code)
            RestoreResult.Success
        } else {
            RestoreResult.NotFound
        }
    }

    /** 当前高级版用户的激活码(供设置页"查看我的激活码"与自助换机);非 PRO 返回 null。 */
    fun purchasedCode(): String? = if (_isPro.value) prefs.getString("code", null) else null

    // ---------------------------------------------------------------- 定价
    // 定价由服务端说了算(改价 = 改服务器的 pricing.json,不用发版)。两个拉取时机:
    //   · App 启动:每天最多一次,让常态下弹窗一打开价格就已经是新的,不必等网络
    //   · 打开高级版弹窗:短节流再拉一次——启动那次多半没赶上(用户开 App 时可能已经
    //     连着相机热点,没外网),而这一刻他正要花钱,值得为准确性再打一次
    // 拉到就写进 prefs 长期留着,不设过期:相机热点没外网是本 App 的常态,
    // 缓存一过期就没价可显示了。从没拉到过(全新安装且一直无外网)才回落到编译时兜底值。
    //
    // 先用缓存渲染、拉到再静默更新:不阻塞弹窗。价格真变了才会当着用户的面跳一下,
    // 而那正是该跳的时候——显示一个假价比跳一下糟得多。
    //
    // ★ 展示价允许过时,收钱不允许:真正要收多少由 /v1/order/create 的响应带回来
    //   (见 [OrderResult.Pending.priceFen]),付款页显示的一定是那个数。
    private const val FALLBACK_PRICE_FEN = 1990
    private const val FALLBACK_ORIGINAL_FEN = 3990
    private const val FALLBACK_PERIOD_DAYS = 365
    private const val PRICE_REFRESH_MS = 24 * 3600_000L
    // 弹窗反复开关时别每次都打服务器;60 秒足够挡住误触,又不至于让人看到隔夜的价。
    private const val PRICE_REFRESH_OPEN_MS = 60_000L

    /** [originalFen] 为 0 表示不划线;[priceFen] 恒 > 0。 */
    enum class ProductId(val wireValue: String) {
        ANNUAL("annual"),
        LIFETIME("lifetime");

        companion object {
            /** Old servers and old pending orders have no product field and always mean annual. */
            fun fromWire(value: String?): ProductId? {
                if (value.isNullOrBlank()) return ANNUAL
                return entries.firstOrNull { it.wireValue == value.lowercase(Locale.US) }
            }
        }
    }

    data class ProductPricing(
        val priceFen: Int,
        val originalFen: Int,
        val periodDays: Int,
        val available: Boolean,
    )

    data class Pricing(
        val annual: ProductPricing,
        val lifetime: ProductPricing,
    ) {
        fun forProduct(product: ProductId): ProductPricing =
            if (product == ProductId.ANNUAL) annual else lifetime
    }

    private fun fallbackPricing() = Pricing(
        annual = ProductPricing(
            FALLBACK_PRICE_FEN,
            FALLBACK_ORIGINAL_FEN,
            FALLBACK_PERIOD_DAYS,
            available = true,
        ),
        // Never compile a placeholder lifetime price into the APK.
        lifetime = ProductPricing(0, 0, 0, available = false),
    )

    private val _pricing = MutableStateFlow(fallbackPricing())
    val pricing: StateFlow<Pricing> get() = _pricing

    private fun loadCachedPricing() {
        val annualPrice = prefs.getInt("price_fen", 0)
        val annual = if (annualPrice > 0) {
            ProductPricing(
                annualPrice,
                prefs.getInt("price_original_fen", 0),
                prefs.getInt("price_period_days", FALLBACK_PERIOD_DAYS).coerceAtLeast(1),
                available = true,
            )
        } else {
            fallbackPricing().annual
        }
        val lifetimePrice = prefs.getInt("lifetime_price_fen", 0)
        val lifetimeAvailable = prefs.getBoolean("lifetime_available", false) && lifetimePrice > 0
        _pricing.value = Pricing(
            annual,
            ProductPricing(
                if (lifetimeAvailable) lifetimePrice else 0,
                if (lifetimeAvailable) prefs.getInt("lifetime_original_fen", 0) else 0,
                0,
                lifetimeAvailable,
            ),
        )
    }

    /** 距上次成功拉价不足 [minAgeMs] 就跳过。拉不到就继续用缓存,不清不改。 */
    private suspend fun fetchPricing(minAgeMs: Long) {
        // An APK upgrade may have a fresh legacy annual-only cache. Fetch once immediately so
        // the newly introduced lifetime product is not hidden by the old cache timestamp.
        if (prefs.getInt("pricing_catalog_version", 0) >= 2 &&
            System.currentTimeMillis() - prefs.getLong("price_at", 0L) < minAgeMs
        ) return
        val resp = get("/v1/pricing") ?: return
        if (!resp.optBoolean("ok")) return
        val products = resp.optJSONObject("products")
        val annualJson = products?.optJSONObject(ProductId.ANNUAL.wireValue)
        val annualPrice = annualJson?.optInt("price_fen", 0)
            ?.takeIf { it > 0 }
            ?: resp.optInt("price_fen", 0)
        if (annualPrice <= 0) return
        val annualOriginal = annualJson?.optInt("original_fen", 0)
            ?: resp.optInt("original_fen", 0)
        val annualDays = (annualJson?.optInt("period_days", FALLBACK_PERIOD_DAYS)
            ?: resp.optInt("period_days", FALLBACK_PERIOD_DAYS)).coerceAtLeast(1)
        val lifetimeJson = products?.optJSONObject(ProductId.LIFETIME.wireValue)
        val lifetimePrice = lifetimeJson?.optInt("price_fen", 0) ?: 0
        val lifetimeAvailable =
            lifetimeJson?.optBoolean("available", false) == true && lifetimePrice > 0
        val catalog = Pricing(
            annual = ProductPricing(
                annualPrice,
                annualOriginal,
                annualDays,
                available = annualJson?.optBoolean("available", true) != false,
            ),
            lifetime = ProductPricing(
                if (lifetimeAvailable) lifetimePrice else 0,
                if (lifetimeAvailable) lifetimeJson?.optInt("original_fen", 0) ?: 0 else 0,
                0,
                lifetimeAvailable,
            ),
        )
        prefs.edit()
            // Preserve the old annual cache keys for seamless APK upgrades.
            .putInt("price_fen", catalog.annual.priceFen)
            .putInt("price_original_fen", catalog.annual.originalFen)
            .putInt("price_period_days", catalog.annual.periodDays)
            .putBoolean("lifetime_available", catalog.lifetime.available)
            .putInt("lifetime_price_fen", catalog.lifetime.priceFen)
            .putInt("lifetime_original_fen", catalog.lifetime.originalFen)
            .putInt("pricing_catalog_version", 2)
            .putLong("price_at", System.currentTimeMillis())
            .apply()
        _pricing.value = catalog
    }

    /** 高级版弹窗打开时调:他正要花钱,别让他看着隔夜的价。挂在 IO 上,不阻塞开窗。 */
    fun refreshPricingOnOpen() {
        scope.launch { fetchPricing(PRICE_REFRESH_OPEN_MS) }
    }

    /** 分 → 展示价:1990→"¥19.9",2000→"¥20",1999→"¥19.99"(尾随 0 不显示)。 */
    fun formatPrice(fen: Int): String = "¥" + when {
        fen % 100 == 0 -> (fen / 100).toString()
        fen % 10 == 0 -> String.format(Locale.US, "%.1f", fen / 100.0)
        else -> String.format(Locale.US, "%.2f", fen / 100.0)
    }

    /** 年费摊到每天(分),四舍五入;不足 1 分返回 0,由 UI 决定整行不显示。 */
    fun perDayFen(p: ProductPricing): Int =
        if (p.periodDays > 0) Math.round(p.priceFen.toDouble() / p.periodDays).toInt() else 0

    // ---------------------------------------------------------------- 购买(自动售码)

    sealed class OrderResult {
        /**
         * 有待支付订单。
         * [payQr] 为虎皮椒返回的现成二维码图片地址(微信个人支付主用:展示给用户扫码);
         * [payUrl] 为手机端支付链接(自动判断微信/支付宝环境,作降级)。
         * [renew] 由服务器判定:真 = 这是现有码的续费单(成功页据此说"续费成功"而非"购买成功")。
         */
        data class Pending(
            val order: String,
            val payUrl: String?,
            val payQr: String?,
            val product: ProductId,
            val renew: Boolean = false,
            /** 本单锁定的实收价(分,0 = 服务器没给)。付款页显示它,不显示缓存的展示价。 */
            val priceFen: Int = 0
        ) : OrderResult()
        /** 已支付;code 为服务器发放的激活码(尚未绑定本机,走 [activate])。 */
        data class Paid(
            val order: String,
            val code: String,
            val product: ProductId,
            val renew: Boolean = false,
            val priceFen: Int = 0,
        ) : OrderResult()
        object Unreachable : OrderResult()
        data class Failed(
            val err: String,
            val pendingProduct: ProductId? = null,
        ) : OrderResult()
    }

    /** 上次未走完的订单号:付款后 App 被杀等场景,重开购买页凭它续单不丢码。 */
    data class PendingOrder(val order: String, val product: ProductId?)

    fun pendingOrder(): PendingOrder? {
        val order = prefs.getString("pending_order", null) ?: return null
        val product = prefs.getString("pending_order_product", null)?.let(ProductId::fromWire)
        return PendingOrder(order, product)
    }

    /** 购买闭环走完(激活成功)后清除续单记录。 */
    fun clearPendingOrder() {
        prefs.edit().remove("pending_order").remove("pending_order_product").apply()
    }

    /**
     * [renew] 为真且购买年费 = 给现有年费码续期(按 max(now, 原到期日) + 1 年计)。
     * 永久版始终是独立商品并另发永久码，不会改写或删除原年费码。
     */
    suspend fun createOrder(
        product: ProductId,
        renew: Boolean = false,
    ): OrderResult = withContext(Dispatchers.IO) {
        val resp = post("/v1/order/create", JSONObject().apply {
            put("fp", fingerprint)
            put("product", product.wireValue)
            if (renew) put("renew", true)
        }) ?: return@withContext OrderResult.Unreachable
        val responseProduct = ProductId.fromWire(resp.optString("product"))
            ?: return@withContext OrderResult.Failed("BAD_PRODUCT")
        // 防重复购买:服务器认出本机已是某码的绑定设备 → 直接返码免费恢复,不再收钱。
        if (resp.optBoolean("already_pro")) {
            val owned = resp.optString("code")
            return@withContext if (owned.isNotEmpty()) {
                OrderResult.Paid(
                    "",
                    owned,
                    responseProduct,
                    resp.optBoolean("renew"),
                    resp.optInt("price_fen", 0),
                )
            }
            else OrderResult.Failed(resp.optString("err", "BAD_RESPONSE"))
        }
        val order = resp.optString("order")
        if (!resp.optBoolean("ok") || order.isEmpty())
            return@withContext OrderResult.Failed(
                resp.optString("err", "BAD_RESPONSE"),
                resp.optString("pending_product")
                    .takeIf { it.isNotBlank() }
                    ?.let(ProductId::fromWire),
            )
        prefs.edit()
            .putString("pending_order", order)
            .putString("pending_order_product", responseProduct.wireValue)
            .apply()
        OrderResult.Pending(
            order,
            resp.optString("pay_url").takeIf { it.isNotEmpty() },
            resp.optString("pay_qr").takeIf { it.isNotEmpty() },
            responseProduct,
            resp.optBoolean("renew"),
            resp.optInt("price_fen", 0),
        )
    }

    /** 查单;服务器在确认到账的瞬间发码并随响应返回。[wantUrl] 仅续单时置真。 */
    suspend fun orderStatus(order: String, wantUrl: Boolean = false): OrderResult =
        withContext(Dispatchers.IO) {
            val resp = post("/v1/order/status", JSONObject().apply {
                put("fp", fingerprint)
                put("order", order)
                if (wantUrl) put("want_url", true)
            }) ?: return@withContext OrderResult.Unreachable
            if (!resp.optBoolean("ok"))
                return@withContext OrderResult.Failed(resp.optString("err", "BAD_RESPONSE"))
            val product = ProductId.fromWire(resp.optString("product"))
                ?: return@withContext OrderResult.Failed("BAD_PRODUCT")
            if (prefs.getString("pending_order", null) == order) {
                prefs.edit().putString("pending_order_product", product.wireValue).apply()
            }
            if (resp.optString("status") == "paid") {
                val code = resp.optString("code")
                if (code.isEmpty()) return@withContext OrderResult.Failed("BAD_RESPONSE")
                OrderResult.Paid(
                    order,
                    code,
                    product,
                    resp.optBoolean("renew"),
                    resp.optInt("price_fen", 0),
                )
            } else OrderResult.Pending(
                order,
                resp.optString("pay_url").takeIf { it.isNotEmpty() },
                resp.optString("pay_qr").takeIf { it.isNotEmpty() },
                product,
                resp.optBoolean("renew"),
                resp.optInt("price_fen", 0),
            )
        }

    /**
     * 拉取二维码图片字节(虎皮椒域名,普通 TLS,用默认信任而非连本服务器的 pinned 工厂)。
     * 失败返回 null，由调用方显示可重试错误；服务端已创建的待支付订单不会因此作废。
     */
    suspend fun fetchBytes(url: String): ByteArray? = withContext(Dispatchers.IO) {
        try {
            val conn = URL(url).openConnection() as HttpsURLConnection
            conn.connectTimeout = 8000
            conn.readTimeout = 8000
            conn.instanceFollowRedirects = true   // 虎皮椒 qrcode 接口 302 跳转到最终 PNG,须跟随
            if (conn.responseCode >= 400) return@withContext null
            // 二维码通常只有几十 KiB。限制响应大小，避免异常上游或错误重定向让支付弹窗
            // 一次性读入超大文件并挤爆 App 内存；无 Content-Length 时也按实际读取量截断。
            val maxBytes = 2 * 1024 * 1024
            if (conn.contentLengthLong > maxBytes) return@withContext null
            conn.inputStream.use { input ->
                val output = java.io.ByteArrayOutputStream(
                    conn.contentLength.coerceIn(0, maxBytes)
                )
                val buffer = ByteArray(8192)
                var total = 0
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    total += count
                    if (total > maxBytes) return@withContext null
                    output.write(buffer, 0, count)
                }
                output.toByteArray()
            }
        } catch (_: Exception) {
            null
        }
    }

    // ---------------------------------------------------------------- 检查更新

    /** 服务器描述的最新版本；分享链接/密码仅作为解析服务故障时的浏览器灾备。 */
    data class UpdateInfo(
        val versionCode: Int,
        val versionName: String,
        val minSupportedVersionCode: Int,
        val notes: String,
        val sha256: String,
        val sizeBytes: Long,
        val fallbackUrl: String,
        val fallbackPassword: String
    ) {
        fun isRequired(currentVersionCode: Int): Boolean =
            currentVersionCode < minSupportedVersionCode
    }

    sealed class UpdateResult {
        data class Available(val info: UpdateInfo) : UpdateResult()
        object UpToDate : UpdateResult()
        /** 联不上服务器,或服务器尚未配置版本信息。 */
        object Unreachable : UpdateResult()
    }

    /** 拉取最新版本信息并与 [currentVersionCode] 比较(整数比,不解析版本名)。 */
    suspend fun checkAppUpdate(currentVersionCode: Int): UpdateResult =
        withContext(Dispatchers.IO) {
            val versionName = URLEncoder.encode(BuildConfig.VERSION_NAME, "UTF-8")
            val resp = get(
                "/v1/app/latest?currentVersionCode=$currentVersionCode&currentVersionName=$versionName"
            ) ?: return@withContext UpdateResult.Unreachable
            if (!resp.optBoolean("ok")) return@withContext UpdateResult.Unreachable
            val vc = resp.optInt("versionCode", 0)
            if (vc <= 0) return@withContext UpdateResult.Unreachable
            if (vc <= currentVersionCode) UpdateResult.UpToDate
            else UpdateResult.Available(
                UpdateInfo(
                    versionCode = vc,
                    versionName = resp.optString("versionName"),
                    minSupportedVersionCode = resp.optInt("minSupportedVersionCode", 1),
                    notes = resp.optString("notes"),
                    sha256 = resp.optString("sha256").lowercase(Locale.ROOT),
                    sizeBytes = resp.optLong("sizeBytes", 0L),
                    fallbackUrl = resp.optString("url"),
                    fallbackPassword = resp.optString("password")
                )
            )
        }

    /** 为当前已发布版本换取一次短期下载直链。服务端会拒绝任意/过期 versionCode。 */
    suspend fun resolveAppDownload(versionCode: Int): String? =
        withContext(Dispatchers.IO) {
            val resp = post("/v1/app/download-url", JSONObject().put("versionCode", versionCode))
                ?: return@withContext null
            if (!resp.optBoolean("ok") || resp.optInt("versionCode") != versionCode) {
                return@withContext null
            }
            val url = resp.optString("url")
            if (!url.startsWith("https://")) return@withContext null
            url
        }

    /** 仅统计系统安装器已成功拉起；上报结果不影响安装流程。 */
    suspend fun reportAppInstallTrigger(info: UpdateInfo) = withContext(Dispatchers.IO) {
        post(
            "/v1/app/install-trigger",
            JSONObject()
                .put("sourceVersionCode", BuildConfig.VERSION_CODE)
                .put("sourceVersionName", BuildConfig.VERSION_NAME)
                .put("targetVersionCode", info.versionCode)
        )
    }

    // ---------------------------------------------------------------- 网络

    /** 依次尝试所有服务器地址;全部失败返回 null。业务成败由响应 JSON 的 ok/err 表达。 */
    private fun post(path: String, body: JSONObject): JSONObject? = request(path, body)

    private fun get(path: String): JSONObject? = request(path, null)

    /** [body] 非空走 POST(JSON),为空走 GET;证书 pin 与超时两者共用。 */
    private fun request(path: String, body: JSONObject?): JSONObject? {
        for (base in SERVERS) {
            try {
                val conn = URL(base + path).openConnection() as HttpsURLConnection
                conn.sslSocketFactory = pinnedSocketFactory
                // 证书本身已由 pin 唯一确认,无需再校验主机名(自签证书对裸 IP 签发)
                conn.hostnameVerifier = HostnameVerifier { _, _ -> true }
                conn.connectTimeout = 8000
                // 直链解析还包含一次第三方请求,给它更完整的响应窗口;其它小接口保持 8 秒。
                conn.readTimeout = if (path == "/v1/app/download-url") 20_000 else 8000
                if (body != null) {
                    conn.requestMethod = "POST"
                    conn.doOutput = true
                    conn.setRequestProperty("Content-Type", "application/json")
                    conn.outputStream.use { it.write(body.toString().toByteArray()) }
                } else {
                    conn.requestMethod = "GET"
                }
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
