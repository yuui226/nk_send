package com.ztransfer.update

import android.app.Activity
import android.app.DownloadManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import android.util.Log
import androidx.core.content.FileProvider
import com.ztransfer.BuildConfig
import com.ztransfer.license.LicenseManager
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

/**
 * App 自更新的唯一状态机：检查元数据 → 临时直链 → 直接下载 → 完整性/签名校验 →
 * 系统安装确认。蓝奏云分享信息只作为自动更新失败时的灾备，也不会尝试绕过 Android
 * 的安装授权。
 */
object AppUpdateManager {
    private const val TAG = "AppUpdate"
    private const val PREFS = "app_update"
    private const val CHECK_INTERVAL_MS = 6 * 60 * 60 * 1000L
    private const val PROMPT_INTERVAL_MS = 24 * 60 * 60 * 1000L
    private const val KEY_LAST_CHECK = "last_check"
    private const val KEY_LAST_PROMPT = "last_prompt"
    private const val KEY_IGNORED_VERSION = "ignored_version"
    private const val KEY_CACHED_INFO = "cached_info"
    private const val KEY_DOWNLOAD_ID = "download_id"
    private const val KEY_DOWNLOAD_PATH = "download_path"
    private const val KEY_VERIFIED_PATH = "verified_path"

    enum class Failure {
        RESOLVE,
        DOWNLOAD,
        INVALID_APK,
        INSTALLER_UNAVAILABLE
    }

    sealed class UiState {
        object Idle : UiState()
        object Checking : UiState()
        data class Available(val info: LicenseManager.UpdateInfo) : UiState()
        data class Resolving(val info: LicenseManager.UpdateInfo) : UiState()
        data class Downloading(val info: LicenseManager.UpdateInfo, val progress: Int?) : UiState()
        data class Verifying(val info: LicenseManager.UpdateInfo) : UiState()
        data class Ready(val info: LicenseManager.UpdateInfo, val apk: File) : UiState()
        data class Failed(val info: LicenseManager.UpdateInfo, val failure: Failure) : UiState()
    }

    private lateinit var context: Context
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val checkMutex = Mutex()
    private var downloadJob: Job? = null
    private val _state = MutableStateFlow<UiState>(UiState.Idle)
    val state: StateFlow<UiState> = _state.asStateFlow()

    private val prefs get() = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun init(appContext: Context) {
        if (::context.isInitialized) return
        context = appContext.applicationContext
        scope.launch {
            discardLegacySystemDownload()
            restoreDownloadOrCachedPrompt()
            val cached = decode(prefs.getString(KEY_CACHED_INFO, null))
            val cachedHardUpdate = cached?.isRequired(BuildConfig.VERSION_CODE) == true
            // 强制更新每次启动复查一次，及时取得最新版本和软硬策略。
            if (cachedHardUpdate || System.currentTimeMillis() - prefs.getLong(KEY_LAST_CHECK, 0L) >= CHECK_INTERVAL_MS) {
                check(force = false)
            }
        }
    }

    /** 手动检查会无视“忽略此版本”和每日提示间隔；自动检查不会打扰已忽略版本。 */
    suspend fun check(force: Boolean): LicenseManager.UpdateResult = checkMutex.withLock {
        if (force) _state.value = UiState.Checking
        val result = LicenseManager.checkAppUpdate(BuildConfig.VERSION_CODE)
        when (result) {
            is LicenseManager.UpdateResult.Available -> {
                prefs.edit()
                    .putLong(KEY_LAST_CHECK, System.currentTimeMillis())
                    .putString(KEY_CACHED_INFO, encode(result.info))
                    .apply()
                maybePresent(result.info, force)
            }
            LicenseManager.UpdateResult.UpToDate -> {
                deleteVerifiedApk()
                prefs.edit().putLong(KEY_LAST_CHECK, System.currentTimeMillis())
                    .remove(KEY_CACHED_INFO).apply()
                _state.value = UiState.Idle
            }
            LicenseManager.UpdateResult.Unreachable -> if (force) _state.value = UiState.Idle
        }
        result
    }

    fun postpone(info: LicenseManager.UpdateInfo) {
        if (info.isRequired(BuildConfig.VERSION_CODE)) return
        prefs.edit().putLong(KEY_LAST_PROMPT, System.currentTimeMillis()).apply()
        _state.value = UiState.Idle
    }

    fun ignoreVersion(info: LicenseManager.UpdateInfo) {
        if (info.isRequired(BuildConfig.VERSION_CODE)) return
        prefs.edit().putInt(KEY_IGNORED_VERSION, info.versionCode).apply()
        _state.value = UiState.Idle
    }

    fun download(info: LicenseManager.UpdateInfo) {
        if (_state.value is UiState.Resolving || _state.value is UiState.Downloading) return
        _state.value = UiState.Resolving(info)
        downloadJob = scope.launch {
            val direct = LicenseManager.resolveAppDownload(info.versionCode)
            if (direct == null) {
                // 发布版本可能已变化；刷新一次元数据。版本没变才按真正的解析失败处理。
                when (val refreshed = check(force = false)) {
                    LicenseManager.UpdateResult.UpToDate -> return@launch
                    is LicenseManager.UpdateResult.Available -> {
                        if (refreshed.info.versionCode != info.versionCode) {
                            _state.value = UiState.Available(refreshed.info)
                            return@launch
                        }
                    }
                    LicenseManager.UpdateResult.Unreachable -> Unit
                }
                _state.value = UiState.Failed(info, Failure.RESOLVE)
                return@launch
            }
            val root = context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
            if (root == null) {
                _state.value = UiState.Failed(info, Failure.DOWNLOAD)
                return@launch
            }
            val updateDir = File(root, "updates").apply { mkdirs() }
            val apk = File(updateDir, "ZTransfer-${info.versionCode}.apk")
            val partial = File(updateDir, "${apk.name}.part")
            prefs.edit().remove(KEY_VERIFIED_PATH).apply()
            if (apk.exists() && !apk.delete()) {
                _state.value = UiState.Failed(info, Failure.DOWNLOAD)
                return@launch
            }
            partial.delete()
            prefs.edit().putString(KEY_DOWNLOAD_PATH, apk.absolutePath).apply()
            _state.value = UiState.Downloading(info, 0)
            try {
                val downloaded = downloadWithRetry(info, direct, partial) { progress ->
                    _state.value = UiState.Downloading(info, progress)
                }
                if (!downloaded) {
                    clearDownloadRecord(deleteFile = true)
                    _state.value = UiState.Failed(info, Failure.DOWNLOAD)
                    return@launch
                }
                if (!partial.renameTo(apk)) throw IllegalStateException("无法保存下载文件")
                verifyDownloaded(info)
            } catch (_: CancellationException) {
                partial.delete()
            } catch (e: Exception) {
                Log.e(TAG, "更新下载处理失败", e)
                partial.delete()
                clearDownloadRecord(deleteFile = true)
                _state.value = UiState.Failed(info, Failure.DOWNLOAD)
            }
        }
    }

    fun cancelDownload(info: LicenseManager.UpdateInfo) {
        if (info.isRequired(BuildConfig.VERSION_CODE)) return
        downloadJob?.cancel()
        downloadJob = null
        clearDownloadRecord(deleteFile = true)
        context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
            ?.resolve("updates/ZTransfer-${info.versionCode}.apk.part")
            ?.delete()
        _state.value = UiState.Idle
    }

    fun unknownSourcesIntent(): Intent? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || context.packageManager.canRequestPackageInstalls()) {
            return null
        }
        return Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${context.packageName}"))
    }

    /** 返回 false 表示系统里没有可处理 APK 的安装器。 */
    fun launchInstaller(activity: Activity, ready: UiState.Ready): Boolean {
        if (unknownSourcesIntent() != null) return false
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.update-files", ready.apk)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return runCatching {
            activity.startActivity(intent)
            scope.launch { LicenseManager.reportAppInstallTrigger(ready.info) }
            true
        }.getOrElse {
            _state.value = UiState.Failed(ready.info, Failure.INSTALLER_UNAVAILABLE)
            false
        }
    }

    private fun maybePresent(info: LicenseManager.UpdateInfo, force: Boolean) {
        val required = info.isRequired(BuildConfig.VERSION_CODE)
        val now = System.currentTimeMillis()
        val ignored = prefs.getInt(KEY_IGNORED_VERSION, -1) == info.versionCode
        val promptDue = now - prefs.getLong(KEY_LAST_PROMPT, 0L) >= PROMPT_INTERVAL_MS
        if (force || required || (!ignored && promptDue)) {
            prefs.edit().putLong(KEY_LAST_PROMPT, now).apply()
            _state.value = UiState.Available(info)
        } else if (_state.value is UiState.Checking) {
            _state.value = UiState.Idle
        }
    }

    private suspend fun restoreDownloadOrCachedPrompt() {
        val info = decode(prefs.getString(KEY_CACHED_INFO, null)) ?: return
        if (info.versionCode <= BuildConfig.VERSION_CODE) {
            deleteVerifiedApk()
            prefs.edit().remove(KEY_CACHED_INFO).apply()
            return
        }
        val verified = prefs.getString(KEY_VERIFIED_PATH, null)?.let(::File)
        if (verified?.isFile == true) {
            // 进程可能在系统“允许此来源”页面被回收；重新校验后直接恢复安装按钮。
            prefs.edit().putString(KEY_DOWNLOAD_PATH, verified.absolutePath).apply()
            verifyDownloaded(info)
            return
        }
        val path = prefs.getString(KEY_DOWNLOAD_PATH, null)
        if (path != null && File(path).isFile) {
            verifyDownloaded(info)
        } else {
            clearDownloadRecord(deleteFile = true)
            maybePresent(info, force = false)
        }
    }

    private suspend fun downloadWithRetry(
        info: LicenseManager.UpdateInfo,
        firstUrl: String,
        target: File,
        onProgress: (Int?) -> Unit
    ): Boolean {
        var directUrl = firstUrl
        repeat(2) { attempt ->
            target.delete()
            onProgress(0)
            try {
                downloadDirect(directUrl, target, info.sizeBytes, onProgress)
                return true
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.w(TAG, "直链下载失败，attempt=${attempt + 1}", e)
                if (attempt == 0) {
                    directUrl = LicenseManager.resolveAppDownload(info.versionCode) ?: return false
                }
            }
        }
        return false
    }

    private suspend fun downloadDirect(
        directUrl: String,
        target: File,
        expectedSize: Long,
        onProgress: (Int?) -> Unit
    ) {
        val connection = URL(directUrl).openConnection() as HttpURLConnection
        try {
            connection.instanceFollowRedirects = true
            connection.connectTimeout = 15_000
            connection.readTimeout = 30_000
            connection.setRequestProperty("Accept", "application/vnd.android.package-archive,*/*")
            connection.setRequestProperty("Accept-Encoding", "identity")
            connection.setRequestProperty("User-Agent", "ZTransfer/${BuildConfig.VERSION_NAME} Android")
            val status = connection.responseCode
            if (status !in 200..299) throw IllegalStateException("下载响应 $status")

            val total = connection.contentLengthLong.takeIf { it > 0 } ?: expectedSize.takeIf { it > 0 }
            var downloaded = 0L
            var lastProgress = -1
            connection.inputStream.buffered().use { input ->
                target.outputStream().buffered().use { output ->
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        currentCoroutineContext().ensureActive()
                        output.write(buffer, 0, count)
                        downloaded += count
                        val progress = total?.let {
                            ((downloaded * 100) / it).toInt().coerceIn(0, 99)
                        }
                        if (progress == null || progress != lastProgress) {
                            onProgress(progress)
                            if (progress != null) lastProgress = progress
                        }
                    }
                }
            }
            currentCoroutineContext().ensureActive()
            if (downloaded <= 0) throw IllegalStateException("下载内容为空")
        } finally {
            connection.disconnect()
        }
    }

    /** 清掉升级前由 DownloadManager 创建、可能永久等待的旧任务。 */
    private fun discardLegacySystemDownload() {
        val id = prefs.getLong(KEY_DOWNLOAD_ID, -1L)
        if (id >= 0) {
            runCatching {
                val manager = context.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
                manager.remove(id)
            }
            prefs.getString(KEY_DOWNLOAD_PATH, null)?.let { File(it).delete() }
        }
        prefs.edit().remove(KEY_DOWNLOAD_ID).remove(KEY_DOWNLOAD_PATH).apply()
    }

    private suspend fun verifyDownloaded(info: LicenseManager.UpdateInfo) = withContext(Dispatchers.IO) {
        _state.value = UiState.Verifying(info)
        val path = prefs.getString(KEY_DOWNLOAD_PATH, null)
        val apk = path?.let(::File)
        if (apk == null || !apk.isFile) {
            return@withContext failVerification(info, Failure.DOWNLOAD, apk, "下载文件不存在")
        }
        if (info.sizeBytes > 0 && apk.length() != info.sizeBytes) {
            return@withContext failVerification(
                info, Failure.INVALID_APK, apk,
                "文件大小不符 actual=${apk.length()} expected=${info.sizeBytes}"
            )
        }
        if (info.sha256.isNotEmpty() && sha256(apk) != info.sha256) {
            return@withContext failVerification(info, Failure.INVALID_APK, apk, "SHA-256 不符")
        }
        val archive = archiveInfo(apk)
            ?: return@withContext failVerification(info, Failure.INVALID_APK, apk, "无法解析 APK")
        if (archive.packageName != context.packageName) {
            return@withContext failVerification(
                info, Failure.INVALID_APK, apk,
                "包名不符 actual=${archive.packageName} expected=${context.packageName}"
            )
        }
        if (versionCode(archive) != info.versionCode.toLong()) {
            return@withContext failVerification(
                info, Failure.INVALID_APK, apk,
                "版本号不符 actual=${versionCode(archive)} expected=${info.versionCode}"
            )
        }
        val installed = runCatching {
            context.packageManager.getPackageInfo(context.packageName, signatureFlags())
        }.getOrNull()
            ?: return@withContext failVerification(info, Failure.INVALID_APK, apk, "无法读取当前 App 签名")
        val archiveSigners = signingDigests(archive)
        if (archiveSigners.isEmpty() || archiveSigners != signingDigests(installed)) {
            return@withContext failVerification(info, Failure.INVALID_APK, apk, "APK 签名不一致")
        }
        prefs.edit().remove(KEY_DOWNLOAD_ID).remove(KEY_DOWNLOAD_PATH)
            .putString(KEY_VERIFIED_PATH, apk.absolutePath).apply()
        _state.value = UiState.Ready(info, apk)
    }

    @Suppress("DEPRECATION")
    private fun archiveInfo(apk: File): PackageInfo? {
        val info = context.packageManager.getPackageArchiveInfo(
            apk.absolutePath, signatureFlags()
        ) ?: return null
        info.applicationInfo?.sourceDir = apk.absolutePath
        info.applicationInfo?.publicSourceDir = apk.absolutePath
        return info
    }

    @Suppress("DEPRECATION")
    private fun signingDigests(info: PackageInfo): Set<String> {
        val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.signingInfo?.apkContentsSigners.orEmpty()
        } else {
            info.signatures.orEmpty()
        }
        return signatures.map { bytesToHex(MessageDigest.getInstance("SHA-256").digest(it.toByteArray())) }.toSet()
    }

    @Suppress("DEPRECATION")
    private fun signatureFlags(): Int = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
        PackageManager.GET_SIGNING_CERTIFICATES
    } else {
        PackageManager.GET_SIGNATURES
    }

    @Suppress("DEPRECATION")
    private fun versionCode(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode else info.versionCode.toLong()

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().buffered().use { input ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val n = input.read(buffer)
                if (n < 0) break
                digest.update(buffer, 0, n)
            }
        }
        return bytesToHex(digest.digest())
    }

    private fun bytesToHex(bytes: ByteArray): String =
        bytes.joinToString("") { "%02x".format(it.toInt() and 0xff) }

    private fun failVerification(
        info: LicenseManager.UpdateInfo,
        failure: Failure,
        apk: File?,
        detail: String
    ) {
        Log.e(TAG, "更新校验失败: $detail")
        apk?.delete()
        prefs.edit().remove(KEY_VERIFIED_PATH).apply()
        clearDownloadRecord(deleteFile = false)
        _state.value = UiState.Failed(info, failure)
    }

    private fun clearDownloadRecord(deleteFile: Boolean) {
        if (deleteFile) prefs.getString(KEY_DOWNLOAD_PATH, null)?.let { File(it).delete() }
        prefs.edit().remove(KEY_DOWNLOAD_ID).remove(KEY_DOWNLOAD_PATH).apply()
    }

    private fun deleteVerifiedApk() {
        prefs.getString(KEY_VERIFIED_PATH, null)?.let { File(it).delete() }
        prefs.edit().remove(KEY_VERIFIED_PATH).apply()
    }

    private fun currentInfo(): LicenseManager.UpdateInfo? = when (val value = _state.value) {
        is UiState.Available -> value.info
        is UiState.Resolving -> value.info
        is UiState.Downloading -> value.info
        is UiState.Verifying -> value.info
        is UiState.Ready -> value.info
        is UiState.Failed -> value.info
        else -> decode(prefs.getString(KEY_CACHED_INFO, null))
    }

    private fun encode(info: LicenseManager.UpdateInfo): String = JSONObject()
        .put("versionCode", info.versionCode)
        .put("versionName", info.versionName)
        .put("minSupportedVersionCode", info.minSupportedVersionCode)
        .put("notes", info.notes)
        .put("sha256", info.sha256)
        .put("sizeBytes", info.sizeBytes)
        .put("fallbackUrl", info.fallbackUrl)
        .put("fallbackPassword", info.fallbackPassword)
        .toString()

    private fun decode(raw: String?): LicenseManager.UpdateInfo? = runCatching {
        val j = JSONObject(raw ?: return null)
        LicenseManager.UpdateInfo(
            versionCode = j.getInt("versionCode"),
            versionName = j.optString("versionName"),
            minSupportedVersionCode = j.optInt("minSupportedVersionCode", 1),
            notes = j.optString("notes"),
            sha256 = j.optString("sha256"),
            sizeBytes = j.optLong("sizeBytes", 0L),
            fallbackUrl = j.optString("fallbackUrl"),
            fallbackPassword = j.optString("fallbackPassword")
        )
    }.getOrNull()
}
