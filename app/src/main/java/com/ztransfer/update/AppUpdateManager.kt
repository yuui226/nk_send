package com.ztransfer.update

import android.app.Activity
import android.app.DownloadManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import android.util.Log
import androidx.core.content.FileProvider
import com.ztransfer.BuildConfig
import com.ztransfer.R
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

/**
 * App 自更新的唯一状态机：检查元数据 → 领取版本地址 → 直接下载 → 轻量版本预检 →
 * 系统安装确认。旧发布的蓝奏云字段只保留兼容，也不会尝试绕过 Android 的安装授权。
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
    private var fixedDownloadJob: Job? = null

    /** 相机热点没有外网。由界面同步，避免检查失败后把下载打到相机上。 */
    @Volatile
    var cameraApConnected: Boolean = false
        private set

    fun setCameraApConnected(connected: Boolean) {
        cameraApConnected = connected
    }
    private val _state = MutableStateFlow<UiState>(UiState.Idle)
    val state: StateFlow<UiState> = _state.asStateFlow()

    private val prefs get() = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun init(appContext: Context) {
        if (::context.isInitialized) return
        context = appContext.applicationContext
        scope.launch {
            discardLegacySystemDownload()
            restoreDownloadOrCachedPrompt()
            val ready = _state.value as? UiState.Ready
            // 固定地址的包已经下好并准备安装。接着再检查会在服务器仍不可达时把这个文件删掉重下。
            if (ready != null && ready.info.sha256.isEmpty() && ready.info.fallbackUrl.isNotEmpty()) return@launch
            val cached = decode(prefs.getString(KEY_CACHED_INFO, null))
            val cachedHardUpdate = cached?.isRequired(BuildConfig.VERSION_CODE) == true
            // 强制更新每次启动复查一次，及时取得最新版本和软硬策略。
            if (cachedHardUpdate || System.currentTimeMillis() - prefs.getLong(KEY_LAST_CHECK, 0L) >= CHECK_INTERVAL_MS) {
                check(force = false)
            }
        }
    }

    /**
     * 手动检查会无视“忽略此版本”和每日提示间隔；自动检查不会打扰已忽略版本。
     * 服务器或域名不可达时，从固定地址下载安装包。能读到版本且不比当前新，就不当作更新。
     */
    suspend fun check(force: Boolean, allowFixedFallback: Boolean = true): LicenseManager.UpdateResult =
        checkMutex.withLock {
            if (force) _state.value = UiState.Checking
            when (val result = LicenseManager.checkAppUpdate(BuildConfig.VERSION_CODE)) {
                is LicenseManager.UpdateResult.Available -> {
                    prefs.edit()
                        .putLong(KEY_LAST_CHECK, System.currentTimeMillis())
                        .putString(KEY_CACHED_INFO, encode(result.info))
                        .apply()
                    maybePresent(result.info, force)
                    result
                }
                LicenseManager.UpdateResult.UpToDate -> {
                    deleteVerifiedApk()
                    prefs.edit().putLong(KEY_LAST_CHECK, System.currentTimeMillis())
                        .remove(KEY_CACHED_INFO).apply()
                    _state.value = UiState.Idle
                    result
                }
                LicenseManager.UpdateResult.Unreachable -> {
                    if (allowFixedFallback) downloadFixedRelease(force)
                    else {
                        if (force) _state.value = UiState.Idle
                        result
                    }
                }
            }
        }

    fun postpone(info: LicenseManager.UpdateInfo) {
        if (info.isRequired(BuildConfig.VERSION_CODE)) return
        fixedDownloadJob?.cancel()
        prefs.edit().putLong(KEY_LAST_PROMPT, System.currentTimeMillis()).apply()
        _state.value = UiState.Idle
    }

    fun ignoreVersion(info: LicenseManager.UpdateInfo) {
        if (info.isRequired(BuildConfig.VERSION_CODE)) return
        prefs.edit().putInt(KEY_IGNORED_VERSION, info.versionCode).apply()
        _state.value = UiState.Idle
    }

    /**
     * 授权服务器不可达时直接取固定地址，展示进度并提供复制链接/浏览器下载入口。
     * 只有安装包确实更新或系统读不出版本时才进入安装。两条路都失败时，手动检查
     * 保留失败弹窗，自动检查恢复空闲。
     */
    private suspend fun downloadFixedRelease(force: Boolean): LicenseManager.UpdateResult =
        withContext(Dispatchers.IO) {
            fixedDownloadJob = coroutineContext[Job]
            val url = context.getString(R.string.update_fixed_download_url)
            val placeholder = fixedReleaseInfo(versionCode = 0, versionName = "", required = false, url = url)
            if (cameraApConnected) {
                if (force) _state.value = UiState.Idle
                return@withContext LicenseManager.UpdateResult.Unreachable
            }
            val root = context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
            val updateDir = root?.let { File(it, "updates").apply { mkdirs() } }
            val apk = updateDir?.let { File(it, "ZTransfer-fixed.apk") }
            val partial = apk?.let { File(it.parentFile, "${it.name}.part") }
            try {
                if (root == null || apk == null || partial == null) {
                    return@withContext failFixedRelease(force, placeholder, Failure.DOWNLOAD)
                }
                _state.value = UiState.Downloading(placeholder, null)
                partial.delete()
                apk.delete()
                prefs.edit().remove(KEY_VERIFIED_PATH)
                    .putString(KEY_DOWNLOAD_PATH, partial.absolutePath).apply()
                downloadDirect(url, partial, 0L) { progress ->
                    _state.value = UiState.Downloading(placeholder, progress)
                }
                if (!partial.renameTo(apk)) throw IllegalStateException("无法保存下载文件")
                prefs.edit().putString(KEY_DOWNLOAD_PATH, apk.absolutePath).apply()
                currentCoroutineContext().ensureActive()
                _state.value = UiState.Verifying(placeholder)
                if (!hasZipMagic(apk)) {
                    return@withContext failFixedRelease(force, placeholder, Failure.INVALID_APK, apk)
                }
                val archive = archiveInfo(apk)
                currentCoroutineContext().ensureActive()
                val actualVersion = archive?.let(::versionCode)
                if (archive != null && archive.packageName != context.packageName) {
                    return@withContext failFixedRelease(force, placeholder, Failure.INVALID_APK, apk)
                }
                if (!isFixedReleaseInstallable(actualVersion, BuildConfig.VERSION_CODE.toLong())) {
                    apk.delete()
                    clearDownloadRecord(deleteFile = false)
                    _state.value = UiState.Idle
                    return@withContext LicenseManager.UpdateResult.UpToDate
                }
                val info = fixedReleaseInfo(
                    versionCode = actualVersion?.toInt() ?: BuildConfig.VERSION_CODE + 1,
                    versionName = archive?.versionName.orEmpty(),
                    required = actualVersion != null,
                    url = url
                )
                prefs.edit().remove(KEY_DOWNLOAD_ID).remove(KEY_DOWNLOAD_PATH)
                    .putString(KEY_VERIFIED_PATH, apk.absolutePath)
                    .putString(KEY_CACHED_INFO, encode(info)).apply()
                _state.value = UiState.Ready(info, apk)
                LicenseManager.UpdateResult.Available(info)
            } catch (_: CancellationException) {
                partial?.delete()
                if (_state.value is UiState.Downloading || _state.value is UiState.Verifying) {
                    _state.value = UiState.Idle
                }
                LicenseManager.UpdateResult.Unreachable
            } catch (e: Exception) {
                Log.w(TAG, "固定地址下载失败", e)
                partial?.delete()
                failFixedRelease(force, placeholder, Failure.DOWNLOAD, apk)
            } finally {
                if (fixedDownloadJob == coroutineContext[Job]) fixedDownloadJob = null
            }
        }

    private fun failFixedRelease(
        force: Boolean,
        info: LicenseManager.UpdateInfo,
        failure: Failure,
        apk: File? = null
    ): LicenseManager.UpdateResult {
        apk?.delete()
        clearDownloadRecord(deleteFile = false)
        _state.value = if (force) UiState.Failed(info, failure) else UiState.Idle
        return LicenseManager.UpdateResult.Unreachable
    }

    private fun fixedReleaseInfo(
        versionCode: Int,
        versionName: String,
        required: Boolean,
        url: String
    ) = LicenseManager.UpdateInfo(
        versionCode = versionCode,
        versionName = versionName,
        minSupportedVersionCode = if (required && versionCode > 0) versionCode else 1,
        notes = "",
        sha256 = "",
        sizeBytes = 0L,
        fallbackUrl = url,
        fallbackPassword = ""
    )

    fun download(info: LicenseManager.UpdateInfo) {
        if (_state.value is UiState.Resolving || _state.value is UiState.Downloading) return
        _state.value = UiState.Resolving(info)
        downloadJob = scope.launch {
            val direct = LicenseManager.resolveAppDownload(info.versionCode)
            if (direct == null) {
                // 发布版本可能已变化；刷新一次元数据。版本没变才按真正的地址领取失败处理。
                when (val refreshed = check(force = false, allowFixedFallback = false)) {
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
        fixedDownloadJob?.cancel()
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
        // 下载链接和元数据都由自有服务端下发。这里只做轻量版本检查，不再预读签名、
        // 比较 SHA/文件大小或重复判断包名：部分鸿蒙系统无法通过 PackageManager 正常
        // 返回归档签名，会把正确 APK 误判为损坏；真正安装时系统安装器仍会强制检查
        // APK 格式、包名、签名兼容性和降级安装。
        val actualVersion = archiveInfo(apk)?.let(::versionCode)
        if (!isDownloadedVersionAcceptable(actualVersion, info.versionCode)) {
            return@withContext failVerification(
                info, Failure.INVALID_APK, apk,
                "版本号不符 actual=$actualVersion expected=${info.versionCode}"
            )
        }
        if (actualVersion == null) {
            Log.w(TAG, "系统无法预读 APK 版本，跳过 App 侧校验并交给系统安装器")
        }
        prefs.edit().remove(KEY_DOWNLOAD_ID).remove(KEY_DOWNLOAD_PATH)
            .putString(KEY_VERIFIED_PATH, apk.absolutePath).apply()
        _state.value = UiState.Ready(info, apk)
    }

    @Suppress("DEPRECATION")
    private fun archiveInfo(apk: File): PackageInfo? {
        val info = context.packageManager.getPackageArchiveInfo(
            apk.absolutePath, 0
        ) ?: return null
        info.applicationInfo?.sourceDir = apk.absolutePath
        info.applicationInfo?.publicSourceDir = apk.absolutePath
        return info
    }

    @Suppress("DEPRECATION")
    private fun versionCode(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode else info.versionCode.toLong()

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

/**
 * 某些鸿蒙系统无法从未安装 APK 读取 PackageInfo。此时不在 App 内误杀下载结果，
 * 直接交给具备最终安全校验职责的系统安装器；只有明确读到错误版本时才拒绝。
 */
internal fun isDownloadedVersionAcceptable(actualVersion: Long?, expectedVersion: Int): Boolean =
    actualVersion == null || actualVersion == expectedVersion.toLong()

/** 固定地址没有服务端声明的版本号。读不到归档版本时交给系统安装器，读到了就必须更高。 */
internal fun isFixedReleaseInstallable(actualVersion: Long?, installedVersion: Long): Boolean =
    actualVersion == null || actualVersion > installedVersion

/** 固定地址在读不到版本时会交给安装器，因此必须先确认这是一个 ZIP/APK，而不是错误页。 */
internal fun hasZipMagic(header: ByteArray): Boolean =
    header.size >= 4 &&
        header[0] == 0x50.toByte() &&
        header[1] == 0x4B.toByte() &&
        header[2] == 0x03.toByte() &&
        header[3] == 0x04.toByte()

internal fun hasZipMagic(file: File): Boolean = runCatching {
    file.inputStream().use { input ->
        val header = ByteArray(4)
        input.read(header) == 4 && hasZipMagic(header)
    }
}.getOrDefault(false)
