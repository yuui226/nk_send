package com.ztransfer.update

import android.app.Activity
import android.app.DownloadManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import com.ztransfer.BuildConfig
import com.ztransfer.license.LicenseManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest

/**
 * App 自更新的唯一状态机：检查元数据 → 临时直链 → DownloadManager → 完整性/签名校验 →
 * 系统安装确认。蓝奏云分享信息只作为自动更新失败时的灾备，也不会尝试绕过 Android
 * 的安装授权。
 */
object AppUpdateManager {
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
    private var progressJob: Job? = null
    private val _state = MutableStateFlow<UiState>(UiState.Idle)
    val state: StateFlow<UiState> = _state.asStateFlow()

    private val prefs get() = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private val downloads get() = context.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager

    private val downloadReceiver = object : BroadcastReceiver() {
        override fun onReceive(receiverContext: Context?, intent: Intent?) {
            if (intent?.action != DownloadManager.ACTION_DOWNLOAD_COMPLETE) return
            val id = intent.getLongExtra(DownloadManager.EXTRA_DOWNLOAD_ID, -1L)
            if (id == prefs.getLong(KEY_DOWNLOAD_ID, -2L)) scope.launch { inspectDownload(id) }
        }
    }

    fun init(appContext: Context) {
        if (::context.isInitialized) return
        context = appContext.applicationContext
        ContextCompat.registerReceiver(
            context,
            downloadReceiver,
            IntentFilter(DownloadManager.ACTION_DOWNLOAD_COMPLETE),
            ContextCompat.RECEIVER_EXPORTED
        )
        scope.launch {
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
        scope.launch {
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
            prefs.edit().remove(KEY_VERIFIED_PATH).apply()
            if (apk.exists() && !apk.delete()) {
                _state.value = UiState.Failed(info, Failure.DOWNLOAD)
                return@launch
            }
            val id = runCatching {
                val request = DownloadManager.Request(Uri.parse(direct))
                    .setTitle("ZTransfer ${info.versionName}")
                    .setDescription("Downloading update")
                    .setMimeType("application/vnd.android.package-archive")
                    .setAllowedOverMetered(true)
                    .setAllowedOverRoaming(false)
                    .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
                    .setDestinationInExternalFilesDir(
                        context,
                        Environment.DIRECTORY_DOWNLOADS,
                        "updates/${apk.name}"
                    )
                downloads.enqueue(request)
            }.getOrElse {
                _state.value = UiState.Failed(info, Failure.DOWNLOAD)
                return@launch
            }
            prefs.edit().putLong(KEY_DOWNLOAD_ID, id).putString(KEY_DOWNLOAD_PATH, apk.absolutePath).apply()
            _state.value = UiState.Downloading(info, null)
            watchProgress(id)
        }
    }

    fun cancelDownload(info: LicenseManager.UpdateInfo) {
        if (info.isRequired(BuildConfig.VERSION_CODE)) return
        val id = prefs.getLong(KEY_DOWNLOAD_ID, -1L)
        if (id >= 0) downloads.remove(id)
        clearDownloadRecord(deleteFile = true)
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
        val id = prefs.getLong(KEY_DOWNLOAD_ID, -1L)
        val path = prefs.getString(KEY_DOWNLOAD_PATH, null)
        if (id >= 0 && path != null) {
            inspectDownload(id)
        } else {
            maybePresent(info, force = false)
        }
    }

    private fun watchProgress(id: Long) {
        progressJob?.cancel()
        progressJob = scope.launch {
            while (true) {
                val info = currentInfo() ?: return@launch
                val cursor = runCatching {
                    downloads.query(DownloadManager.Query().setFilterById(id))
                }.getOrElse {
                    _state.value = UiState.Failed(info, Failure.DOWNLOAD)
                    return@launch
                }
                cursor.use {
                    if (!it.moveToFirst()) {
                        _state.value = UiState.Failed(info, Failure.DOWNLOAD)
                        return@launch
                    }
                    val status = it.getInt(it.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))
                    if (status == DownloadManager.STATUS_SUCCESSFUL || status == DownloadManager.STATUS_FAILED) {
                        inspectDownload(id)
                        return@launch
                    }
                    val done = it.getLong(it.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR))
                    val total = it.getLong(it.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES))
                    val progress = if (total > 0) ((done * 100) / total).toInt().coerceIn(0, 99) else null
                    _state.value = UiState.Downloading(info, progress)
                }
                delay(750)
            }
        }
    }

    private suspend fun inspectDownload(id: Long) {
        val info = currentInfo() ?: return
        val cursor = runCatching {
            downloads.query(DownloadManager.Query().setFilterById(id))
        }.getOrElse {
            clearDownloadRecord(deleteFile = true)
            _state.value = UiState.Failed(info, Failure.DOWNLOAD)
            return
        }
        val status = cursor.use {
            if (!it.moveToFirst()) -1
            else it.getInt(it.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))
        }
        when (status) {
            DownloadManager.STATUS_SUCCESSFUL -> verifyDownloaded(info)
            DownloadManager.STATUS_FAILED, -1 -> {
                clearDownloadRecord(deleteFile = true)
                _state.value = UiState.Failed(info, Failure.DOWNLOAD)
            }
            else -> {
                _state.value = UiState.Downloading(info, null)
                watchProgress(id)
            }
        }
    }

    private suspend fun verifyDownloaded(info: LicenseManager.UpdateInfo) = withContext(Dispatchers.IO) {
        _state.value = UiState.Verifying(info)
        val path = prefs.getString(KEY_DOWNLOAD_PATH, null)
        val apk = path?.let(::File)
        if (apk == null || !apk.isFile) return@withContext failVerification(info, Failure.DOWNLOAD, apk)
        if (info.sizeBytes > 0 && apk.length() != info.sizeBytes) {
            return@withContext failVerification(info, Failure.INVALID_APK, apk)
        }
        if (info.sha256.isNotEmpty() && sha256(apk) != info.sha256) {
            return@withContext failVerification(info, Failure.INVALID_APK, apk)
        }
        val archive = archiveInfo(apk) ?: return@withContext failVerification(info, Failure.INVALID_APK, apk)
        if (archive.packageName != context.packageName) {
            return@withContext failVerification(info, Failure.INVALID_APK, apk)
        }
        if (versionCode(archive) != info.versionCode.toLong()) {
            return@withContext failVerification(info, Failure.INVALID_APK, apk)
        }
        val installed = runCatching {
            context.packageManager.getPackageInfo(context.packageName, signatureFlags())
        }.getOrNull() ?: return@withContext failVerification(info, Failure.INVALID_APK, apk)
        val archiveSigners = signingDigests(archive)
        if (archiveSigners.isEmpty() || archiveSigners != signingDigests(installed)) {
            return@withContext failVerification(info, Failure.INVALID_APK, apk)
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

    private fun failVerification(info: LicenseManager.UpdateInfo, failure: Failure, apk: File?) {
        apk?.delete()
        prefs.edit().remove(KEY_VERIFIED_PATH).apply()
        clearDownloadRecord(deleteFile = false)
        _state.value = UiState.Failed(info, failure)
    }

    private fun clearDownloadRecord(deleteFile: Boolean) {
        progressJob?.cancel()
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
