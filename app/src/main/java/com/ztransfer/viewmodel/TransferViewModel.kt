package com.ztransfer.viewmodel

import android.app.Application
import android.content.Context
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.ztransfer.AppLocale
import com.ztransfer.BuildConfig
import com.ztransfer.R
import com.ztransfer.license.LicenseManager
import com.ztransfer.protocol.NikonCamera
import com.ztransfer.protocol.PtpConstants
import com.ztransfer.protocol.ResumeUnavailableException
import com.ztransfer.service.TransferService
import com.ztransfer.ui.theme.ThemeMode
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

enum class TransferStatus {
    WAITING, TRANSFERING, COMPLETED, FAILED, CANCELLED
}

data class TransferTask(
    val file: NikonCamera.FileInfo,
    val status: TransferStatus = TransferStatus.WAITING,
    val progress: Float = 0f,
    val speed: Long = 0,
    val downloaded: Long = 0,
    val error: String? = null,
    val skipped: Boolean = false,  // 目标目录已存在同名文件而跳过
    // 单文件下载速度（MB/s），完成后填入，显示在卡片上。
    val downloadMBps: Float = 0f,
    // 本次传输耗时（毫秒），完成后填入并显示在卡片上；跳过/未传的为 null。
    val elapsedMs: Long? = null
)

data class TransferState(
    val tasks: List<TransferTask> = emptyList(),
    val isTransferring: Boolean = false,
    val currentSpeed: Long = 0,
    val transferDirUri: String? = null,
    val thumbnailColumns: Int = 3,
    // 触感反馈开关：默认开启，用户关闭后持久化，下次启动保持。
    val hapticsEnabled: Boolean = true,
    // 屏幕常亮（默认开启）：应用在前台时不熄屏——熄屏后系统会冻结进程/让 Wi-Fi 打盹，
    // 相机连接容易断；代价是手机一直亮屏。
    val keepScreenOn: Boolean = true,
    // 主题模式：默认跟随系统深浅色，可在设置里固定深色/浅色。
    val themeMode: ThemeMode = ThemeMode.SYSTEM,
    // 照片类型筛选（归一化扩展名，如 ".jpg"）：null = 全部（不过滤，新类型也放行）。
    // 持久化跨会话生效；设备上没有所选类型时列表自然为空，不做特殊处理。
    val filterExtensions: Set<String>? = null,
    // 只看机内"保护"(🔑)标记过的照片（机内选片工作流）。持久化。
    val filterProtectedOnly: Boolean = false,
    // 只看连拍照片（检测算法见 FileListScreen.computeBurstHandles）。持久化。
    val filterBurstOnly: Boolean = false,
    // 应用内语言：BCP-47 标签（"en"/"zh-Hans"/"zh-Hant"）或 AppLocale.SYSTEM（跟随系统）。
    // 切换后由设置面板触发 Activity.recreate() 生效。
    val appLanguage: String = AppLocale.SYSTEM
)

/** 队列剩余待处理数量（正在传 + 等待传）。供顶栏药丸等复用。 */
val TransferState.remainingCount: Int
    get() = tasks.count { it.status == TransferStatus.WAITING || it.status == TransferStatus.TRANSFERING }

/** 当前正在传输文件的进度（0..1）；没有正在传的返回 0。供顶栏药丸复用传输页的单文件进度语义。 */
val TransferState.currentFileProgress: Float
    get() = tasks.firstOrNull { it.status == TransferStatus.TRANSFERING }?.progress ?: 0f

class TransferViewModel(application: Application) : AndroidViewModel(application) {
    private val _state = MutableStateFlow(TransferState())
    val state: StateFlow<TransferState> = _state.asStateFlow()

    private var transferJob: Job? = null
    private val prefs = application.getSharedPreferences("ztransfer", Context.MODE_PRIVATE)
    private val contentResolver = application.contentResolver

    /** 用户可见文案（错误信息等）统一走字符串资源；经 AppLocale.wrap 与应用内语言一致。 */
    private fun str(resId: Int, vararg args: Any?): String =
        AppLocale.wrap(getApplication()).getString(resId, *args)

    /**
     * 把底层异常翻译成用户可读的三语文案：网络类异常（断联/超时/连接重置——卡片上
     * 曾裸露 "software caused connection abort" 这类系统原文）统一显示"相机连接中断"；
     * 目录失效单独指认；其余保留自带信息（多为我们自己抛出的已本地化业务文案）。
     */
    private fun friendlyError(e: Throwable?): String {
        val msg = e?.message ?: return str(R.string.transfer_failed)
        val connectionLost = e is java.net.SocketException ||
                e is java.net.SocketTimeoutException ||
                e is java.io.EOFException ||
                listOf("connection abort", "connection reset", "broken pipe",
                    "socket", "econn", "etimedout", "network is unreachable")
                    .any { msg.contains(it, ignoreCase = true) }
        return when {
            connectionLost -> str(R.string.error_camera_connection_lost)
            e is java.io.FileNotFoundException -> str(R.string.error_dir_invalid)
            else -> msg
        }
    }

    // 鸿蒙适配：部分华为/荣耀设备的 DocumentsProvider renameDocument 损坏（无论目标名
    // 是否空闲都失败），下载完好的临时文件改不了正式名 → 每张都"保存失败"。
    // 首次确认损坏后置位，本会话后续文件跳过改名直接走"复制为正式文件"回退路径，
    // 不再每个文件白试上百次改名。安卓正常设备永远不会置位，行为零变化。
    private var renameBroken = false

    private companion object {
        const val TAG = "ZTransfer"
        // 未完成文件的临时名前缀（带前导点，在相册中隐藏）。真正文件名只在下载完整后才出现。
        const val PART_PREFIX = ".nkpart_"
        // 重名副本后缀（"DSC_0001 (1).NEF" 中的 " (1)"），用于剥离/生成。
        val COPY_SUFFIX_REGEX = Regex(""" \(\d+\)(?=\.[^.]*$|$)""")
        // 分块大小引用协议层常量，保证断点续传偏移与分块下载粒度的严格一致。
        val RESUME_CHUNK_SIZE: Long get() = NikonCamera.CHUNK_SIZE
    }

    /** 半成品文件信息：用于断点续传。[token] = 文件内容身份（大小+拍摄时间），
     *  防止同名不同文件（DSC 编号跨文件夹回卷）续传时张冠李戴、把两份数据拼接成损坏文件。 */
    private data class PartInfo(val uri: Uri, val size: Long, val token: String)

    /** 文件内容身份令牌：大小+拍摄时间，仅留字母数字与点（内嵌半成品名，不含下划线分隔符）。 */
    private fun identityToken(file: NikonCamera.FileInfo): String =
        "${file.size}.${file.captureDate ?: "0"}".replace(Regex("[^A-Za-z0-9.]"), "")

    /** 半成品文件名 = 前缀 + 身份令牌 + "_" + 原文件名（原名可含下划线，解析按【首个】下划线切分）。 */
    private fun partFileName(file: NikonCamera.FileInfo): String =
        PART_PREFIX + identityToken(file) + "_" + file.fileName

    init {
        val dir = prefs.getString("transfer_dir", null)
        _state.update {
            it.copy(
                transferDirUri = dir,
                thumbnailColumns = prefs.getInt("thumbnail_columns", 3).coerceIn(1, 4),
                hapticsEnabled = prefs.getBoolean("haptics_enabled", true),
                keepScreenOn = prefs.getBoolean("keep_screen_on", true),
                themeMode = prefs.getString("theme_mode", null)
                    ?.let { m -> ThemeMode.entries.firstOrNull { e -> e.name == m } }
                    ?: ThemeMode.SYSTEM,
                // getStringSet 返回的实例不可直接持有（SharedPreferences 约定），拷贝一份。
                filterExtensions = prefs.getStringSet("filter_exts", null)?.toSet(),
                filterProtectedOnly = prefs.getBoolean("filter_protected", false),
                filterBurstOnly = prefs.getBoolean("filter_burst", false),
                appLanguage = prefs.getString(AppLocale.PREF_KEY, AppLocale.SYSTEM) ?: AppLocale.SYSTEM
            )
        }
        // 开 App 时清扫上次崩溃/被杀留下的半成品（.nkpart_ 临时文件）。
        if (dir != null) {
            viewModelScope.launch(Dispatchers.IO) {
                try { sweepAndListExisting(Uri.parse(dir), deleteParts = true) } catch (_: Exception) {}
            }
        }
    }

    fun setThumbnailColumns(columns: Int) {
        val c = columns.coerceIn(1, 4)
        prefs.edit().putInt("thumbnail_columns", c).apply()
        _state.update { it.copy(thumbnailColumns = c) }
    }

    fun setThemeMode(mode: ThemeMode) {
        prefs.edit().putString("theme_mode", mode.name).apply()
        _state.update { it.copy(themeMode = mode) }
    }

    fun setHapticsEnabled(enabled: Boolean) {
        prefs.edit().putBoolean("haptics_enabled", enabled).apply()
        _state.update { it.copy(hapticsEnabled = enabled) }
    }

    fun setKeepScreenOn(enabled: Boolean) {
        prefs.edit().putBoolean("keep_screen_on", enabled).apply()
        _state.update { it.copy(keepScreenOn = enabled) }
    }

    /** 应用内语言；写入后需 Activity.recreate() 才对界面生效（attachBaseContext 重读偏好）。 */
    fun setAppLanguage(tag: String) {
        prefs.edit().putString(AppLocale.PREF_KEY, tag).apply()
        _state.update { it.copy(appLanguage = tag) }
    }

    /** 应用筛选（类型/保护标记/连拍，面板点确定一次性提交）。持久化，跨会话与跨设备连接生效。 */
    fun setFilters(exts: Set<String>?, protectedOnly: Boolean, burstOnly: Boolean) {
        prefs.edit().apply {
            if (exts == null) remove("filter_exts") else putStringSet("filter_exts", exts)
            if (protectedOnly) putBoolean("filter_protected", true) else remove("filter_protected")
            if (burstOnly) putBoolean("filter_burst", true) else remove("filter_burst")
        }.apply()
        _state.update {
            it.copy(
                filterExtensions = exts,
                filterProtectedOnly = protectedOnly,
                filterBurstOnly = burstOnly
            )
        }
    }

    fun setTransferDirUri(uri: Uri) {
        contentResolver.takePersistableUriPermission(
            uri,
            android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    android.content.Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        )
        prefs.edit().putString("transfer_dir", uri.toString()).apply()
        _state.update { it.copy(transferDirUri = uri.toString()) }
    }

    fun addToQueue(files: List<NikonCamera.FileInfo>, cameraProvider: () -> NikonCamera?) {
        // 未设置传输目录时禁止入队（UI 层会把用户引导到设置页）。
        val dirUri = _state.value.transferDirUri ?: return

        // 按 handle 去重：已在队列（任意状态）的不重复入队。这是防御底线——
        // 一旦出现重复 handle，任务列表/缩略图网格的 LazyColumn key 冲突会直接崩溃。
        val queued = _state.value.tasks.mapTo(HashSet()) { it.file.handle }
        val newTasks = files.asSequence()
            .filter { it.handle !in queued }
            .distinctBy { it.handle }
            .map { TransferTask(file = it) }
            .toList()
        if (newTasks.isEmpty()) return
        _state.update { it.copy(tasks = it.tasks + newTasks) }

        if (!_state.value.isTransferring) {
            processQueue(dirUri, cameraProvider)
        }
    }

    private fun processQueue(dirUri: String, cameraProvider: () -> NikonCamera?) {
        if (transferJob?.isActive == true) return

        transferJob = viewModelScope.launch {
            val self = coroutineContext[Job]
            _state.update { it.copy(isTransferring = true) }
            var serviceStarted = false

            try {
                val uri = Uri.parse(dirUri)
                val docUri = DocumentsContract.buildDocumentUriUsingTree(
                    uri,
                    DocumentsContract.getTreeDocumentId(uri)
                )

                // 队列启动前先校验传输目录仍然存在且可访问：目录被删除/改名/换存储后，
                // 后续 createDocument 会抛 "Missing file for primary:..." 这类系统原始
                // 错误直接漏到界面上。失效则清掉设置——用户下次点图会被既有引导
                //（未设目录自动弹设置面板）带去重新选择。
                val dirValid = withContext(Dispatchers.IO) {
                    try {
                        contentResolver.query(
                            docUri,
                            arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID),
                            null, null, null
                        )?.use { true } ?: false
                    } catch (_: Exception) {
                        false
                    }
                }
                if (!dirValid) {
                    prefs.edit().remove("transfer_dir").apply()
                    // 文案只取一次：str() 每次都要构建配置上下文，放 map 里会按任务数重复执行
                    //（update 遇 CAS 重试还会整体重跑）。
                    val dirInvalidMsg = str(R.string.error_dir_invalid)
                    _state.update { s ->
                        s.copy(
                            transferDirUri = null,
                            tasks = s.tasks.map {
                                if (it.status == TransferStatus.WAITING) {
                                    it.copy(status = TransferStatus.FAILED, error = dirInvalidMsg)
                                } else it
                            }
                        )
                    }
                    return@launch   // finally 负责复位 isTransferring（前台服务尚未启动）
                }

                // 单次遍历：保留半成品(.nkpart_)供断点续传 + 建立"已存在(名称->大小)"去重表。
                val (existing, partFiles) = withContext(Dispatchers.IO) {
                    sweepAndListExisting(uri, deleteParts = false)
                }
                // 归一化名 -> 大小集合：把重名冲突时落盘的 "DSC_0001 (1).NEF" 副本也归到
                // "DSC_0001.NEF" 名下参与"已存在则跳过"，跨会话不再重复下载这些副本。
                val existingSizes = HashMap<String, MutableSet<Long>>()
                existing.forEach { (name, size) ->
                    existingSizes.getOrPut(baseName(name)) { HashSet() }.add(size)
                }

                while (true) {
                    // 以 handle（稳定唯一键）定位任务，避免增删任务导致下标串位。
                    val task = _state.value.tasks.firstOrNull { it.status == TransferStatus.WAITING } ?: break
                    val handle = task.file.handle

                    // 目标目录已存在同名文件（大小一致或任一侧大小未知），或已有同大小的重名副本 → 跳过，不重复下载。
                    // 相机对 >4GB 对象报不出真实大小（SIZE_UNKNOWN 哨兵），与磁盘大小必然不等，
                    // 此时按文件名匹配跳过，避免每次重传数 GB 后又落成 " (1)" 副本。
                    val existingSize = existing[task.file.fileName]
                    if ((existingSize != null && (existingSize == task.file.size || existingSize < 0L ||
                            task.file.size == PtpConstants.SIZE_UNKNOWN)) ||
                        existingSizes[task.file.fileName]?.contains(task.file.size) == true
                    ) {
                        log { "DL_SKIP existing: ${task.file.fileName}" }
                        updateTask(handle) {
                            it.copy(
                                status = TransferStatus.COMPLETED,
                                skipped = true,
                                progress = 1f,
                                downloaded = task.file.size,
                                speed = 0
                            )
                        }
                        continue
                    }

                    // 免费版每日完成数已达上限：不再开始新传输，卡片直接标注并引导解锁。
                    // 检查放在"已存在跳过"之后——跳过不占额度，到了上限也照常放行。
                    if (LicenseManager.transferLimitReached()) {
                        updateTask(handle) {
                            it.copy(
                                status = TransferStatus.FAILED,
                                error = str(R.string.transfer_limit_reached),
                                speed = 0
                            )
                        }
                        continue
                    }

                    // 免费版单文件超限（>400MB，长视频/RAW 连拍段）：同样入队不拦、
                    // 轮到才检，卡片标注引导解锁后跳过，队列继续传后面的。
                    // >4GB 对象的 size 是哨兵值，数值上必然超限，一并拦住。
                    if (LicenseManager.freeSizeLimitExceeded(task.file.size)) {
                        updateTask(handle) {
                            it.copy(
                                status = TransferStatus.FAILED,
                                error = str(
                                    R.string.transfer_size_limit,
                                    LicenseManager.FREE_MAX_FILE_BYTES / (1024 * 1024)
                                ),
                                speed = 0
                            )
                        }
                        continue
                    }

                    // 每个任务开始时现取相机实例：中途掉线重连后，后续任务用的是新连接，
                    // 而不是队列启动时捕获的旧实例（旧实例 socket 已死，只会全部快速失败）。
                    val camera = cameraProvider()
                    if (camera == null) {
                        updateTask(handle) {
                            it.copy(status = TransferStatus.FAILED, error = str(R.string.camera_not_connected), speed = 0)
                        }
                        continue
                    }

                    updateTask(handle) { it.copy(status = TransferStatus.TRANSFERING) }
                    // 本次传输计时起点：只在此处与完成处各读一次时钟，不进收包热路径。
                    val transferStart = System.currentTimeMillis()
                    log { "DL_BEGIN: ${task.file.fileName} handle=$handle size=${task.file.size}" }

                    // 首个真正要下载的文件才拉起前台服务（全部命中"已存在"时不必启动，避免通知闪一下）。
                    if (!serviceStarted) {
                        TransferService.start(getApplication())
                        serviceStarted = true
                    }

                    // 断点续传：检查是否存在上次传输留下的、【身份令牌匹配】的半成品文件。
                    var resumeOffset = 0L
                    var fileDocUri: Uri? = null
                    val partFile = partFiles[task.file.fileName]?.takeIf { it.token == identityToken(task.file) }
                    if (partFile != null) {
                        val partSize = partFile.size
                        // task.file.size 对 >4GB 文件是 SIZE_UNKNOWN 哨兵，绝不能拿它当真实大小比较。
                        val sizeKnown = task.file.size > 0 && task.file.size != PtpConstants.SIZE_UNKNOWN
                        if (sizeKnown && partSize >= task.file.size) {
                            // 半成品已达完整大小：上次下载完在改名前崩了，直接改名跳过下载。
                            // 仅在大小【已知】时走此捷径——SIZE_UNKNOWN 下 partSize>=哨兵会把
                            // 4.3GB 的截断视频误判为完整，造成静默数据丢失。
                            log { "DL_RESUME_COMPLETE: ${task.file.fileName} partSize=$partSize" }
                            val finalName = task.file.fileName
                            var renamed = renameQuietly(partFile.uri, finalName)
                            if (renamed == null) {
                                // 改名失败：复用已有副本逻辑
                                for (n in 1..99) {
                                    val candidate = suffixedName(finalName, n)
                                    if (existing.containsKey(candidate)) continue
                                    renamed = renameQuietly(partFile.uri, candidate)
                                    if (renamed != null) break
                                }
                            }
                            if (renamed != null) {
                                existing[finalName] = partSize
                                existingSizes.getOrPut(baseName(finalName)) { HashSet() }.add(partSize)
                                updateTask(handle) {
                                    it.copy(status = TransferStatus.COMPLETED, skipped = true,
                                        progress = 1f, downloaded = partSize, speed = 0)
                                }
                            } else {
                                // 改不了，删半成品让正常路径重下
                                deleteQuietly(partFile.uri)
                            }
                            continue  // 跳过本次下载（无论成功改名还是已删除重下）
                        } else if (partSize >= RESUME_CHUNK_SIZE && (!sizeKnown || partSize < task.file.size)) {
                            // 半成品够大（≥1 块）且未完整：从块边界续传。大小未知(>4GB)也允许——
                            // 由协议层用 GetObjectSize 解析真实大小后做全文件完整性校验。
                            resumeOffset = (partSize / RESUME_CHUNK_SIZE) * RESUME_CHUNK_SIZE
                            fileDocUri = partFile.uri
                            log { "DL_RESUME: ${task.file.fileName} partSize=$partSize resumeOffset=$resumeOffset" }
                        } else {
                            // 太小（<64MB）或异常半成品，删掉重建。
                            deleteQuietly(partFile.uri)
                        }
                    }

                    try {
                        // SAF 的建文件/开流/关闭冲刷都是跨进程 Binder + 磁盘 IO，放 IO 线程，
                        // 不在主线程随每个文件抖一下（状态更新经 StateFlow.update，线程安全）。
                        val result = withContext(Dispatchers.IO) {
                            if (fileDocUri == null) {
                                // 新建临时文件
                                val createdUri = DocumentsContract.createDocument(
                                    contentResolver,
                                    docUri,
                                    getMimeType(task.file.fileName),
                                    partFileName(task.file)
                                ) ?: throw Exception(str(R.string.error_create_file))
                                fileDocUri = createdUri
                            }

                            // 续传时用 ParcelFileDescriptor "rw" 模式实现 seekable 写入；
                            // 新文件用 openOutputStream（截断写入，行为不变）。
                            val outputStream: java.io.OutputStream
                            if (resumeOffset > 0) {
                                val pfd = contentResolver.openFileDescriptor(fileDocUri!!, "rw")
                                    ?: throw Exception(str(R.string.error_open_file))
                                // AutoCloseOutputStream 持有 pfd 所有权：BufferedOutputStream.use{} 关闭
                                // 输出流时一并 close 掉 pfd，既不泄漏 fd，也确保 DocumentsProvider 收到
                                // 写完成信号后才发生改名（裸 FileOutputStream(pfd.fileDescriptor) 两者皆失）。
                                val fos = ParcelFileDescriptor.AutoCloseOutputStream(pfd)
                                fos.channel.position(resumeOffset)
                                outputStream = fos
                            } else {
                                outputStream = contentResolver.openOutputStream(fileDocUri!!)
                                    ?: throw Exception(str(R.string.error_open_file))
                            }

                            // 用大缓冲包裹 SAF 输出流，把零散的写批量化，减少 ContentProvider 往返。
                            // 缺了它，每个 PTP-IP 数据包都要跨 Binder 写一次 SAF，吞吐直接腰斩（2M/s→<1M/s）。
                            java.io.BufferedOutputStream(outputStream, 1024 * 1024).use { out ->
                                camera.downloadToFile(
                                    handle, out,
                                    onProgress = { progress ->
                                        val speed = if (progress.elapsed > 0) {
                                            (progress.downloaded / progress.elapsed).toLong()
                                        } else 0
                                        _state.update { state ->
                                            state.copy(
                                                currentSpeed = speed,
                                                tasks = state.tasks.map { t ->
                                                    if (t.file.handle == handle && t.status == TransferStatus.TRANSFERING) {
                                                        t.copy(
                                                            progress = if (progress.total > 0) {
                                                                progress.downloaded.toFloat() / progress.total
                                                            } else 0f,
                                                            downloaded = progress.downloaded,
                                                            speed = speed
                                                        )
                                                    } else t
                                                }
                                            )
                                        }
                                    },
                                    resumeOffset = resumeOffset,
                                    totalSize = task.file.size
                                )
                            }
                        }
                        // withContext 正常返回则 fileDocUri 必已赋值。
                        val createdUri = checkNotNull(fileDocUri)

                        result.fold(
                            onSuccess = { stats ->
                                // 下载完整 → 把临时名改成真正文件名（相机上报的文件名即为准）。
                                val finalName = task.file.fileName
                                var savedName = finalName
                                var renamedUri = if (renameBroken) null else renameQuietly(createdUri, finalName)
                                if (renamedUri == null && !renameBroken) {
                                    for (n in 1..99) {
                                        val candidate = suffixedName(finalName, n)
                                        if (existing.containsKey(candidate)) continue
                                        renamedUri = renameQuietly(createdUri, candidate)
                                        if (renamedUri != null) {
                                            savedName = candidate
                                            break
                                        }
                                    }
                                }
                                var saveError: Throwable? = null
                                if (renamedUri == null) {
                                    var copyName = finalName
                                    if (existing.containsKey(copyName)) {
                                        for (n in 1..99) {
                                            val candidate = suffixedName(finalName, n)
                                            if (!existing.containsKey(candidate)) {
                                                copyName = candidate
                                                break
                                            }
                                        }
                                    }
                                    val copied = copyAsFallback(
                                        docUri, createdUri, copyName,
                                        getMimeType(finalName), stats.bytes
                                    )
                                    val copiedUri = copied.getOrNull()
                                    if (copiedUri != null) {
                                        renameBroken = true
                                        deleteQuietly(createdUri)
                                        savedName = displayNameOf(copiedUri) ?: copyName
                                        renamedUri = copiedUri
                                        log { "DL_SAVE via copy fallback: $savedName (rename broken)" }
                                    } else {
                                        saveError = copied.exceptionOrNull()
                                    }
                                }
                                if (renamedUri != null) {
                                    existing[savedName] = stats.bytes
                                    existingSizes.getOrPut(baseName(savedName)) { HashSet() }.add(stats.bytes)
                                    val elapsed = System.currentTimeMillis() - transferStart
                                    // 免费额度按"真正传输完成"计数(此处是唯一完成点;
                                    // 跳过/续传改名捷径都不经过这里,不计)。
                                    LicenseManager.recordTransferDone()
                                    updateTask(handle) {
                                        it.copy(
                                            status = TransferStatus.COMPLETED, progress = 1f,
                                            downloaded = stats.bytes, speed = 0,
                                            downloadMBps = stats.mbps,
                                            elapsedMs = elapsed
                                        )
                                    }
                                } else {
                                    // 改名与复制均失败：删掉临时文件并标记失败——
                                    // 重试时从头下载（改名失败不是传输层问题，续传解决不了）。
                                    deleteQuietly(createdUri)
                                    val reason = when {
                                        saveError is java.io.FileNotFoundException ->
                                            str(R.string.error_dir_invalid)
                                        saveError?.message != null -> saveError.message
                                        else -> str(R.string.error_rename_copy_refused)
                                    }
                                    updateTask(handle) {
                                        it.copy(status = TransferStatus.FAILED, error = str(R.string.error_save_failed, reason), speed = 0)
                                    }
                                }
                            },
                            onFailure = { e ->
                                if (e is ResumeUnavailableException) {
                                    // 走不了续传（相机不支持分块 / >4GB 拿不到真实大小）：删掉半成品，
                                    // 本次标记失败，重试将从头全新下载——绝不用错位的全量数据续写。
                                    deleteQuietly(fileDocUri)
                                    updateTask(handle) {
                                        it.copy(status = TransferStatus.FAILED, error = str(R.string.transfer_failed), speed = 0)
                                    }
                                } else {
                                    // 普通传输失败：保留半成品，重试时从块边界续传。
                                    // 不删 .nkpart_：断点续传依赖它，交给 App 启动 init 的 sweep 统一清扫。
                                    updateTask(handle) {
                                        it.copy(status = TransferStatus.FAILED, error = friendlyError(e), speed = 0)
                                    }
                                }
                            }
                        )
                    } catch (e: CancellationException) {
                        // 协程取消只发生在 ViewModel 销毁（App 退出）时——界面上的"停止"
                        // 不再取消协程（正在传的文件自然传完，见 withdrawPending）。
                        // 此处【不】就地删除半成品：半成品交给 App 启动的 sweep 统一清扫
                        //（.nkpart_ 前缀带前导点，相册中本就不可见），也是断点续传的基础。
                        throw e
                    } catch (e: Exception) {
                        // 异常保留半成品——不是传输层错误（如目录失效），但半成品仍有价值
                        // 保留可让用户修好设置后重试时续传。
                        if (BuildConfig.DEBUG) {
                            android.util.Log.e(TAG, "DL_FAIL: ${task.file.fileName} - ${e.javaClass.simpleName}: ${e.message}", e)
                        }
                        updateTask(handle) {
                            it.copy(status = TransferStatus.FAILED, error = friendlyError(e), speed = 0)
                        }
                    }
                }
            } finally {
                // 仅当本协程仍是当前传输 job 时才收尾，避免误停新队列的前台服务/误清传输
                // 状态（旧队列收尾期间新队列可能已启动并接管 transferJob）。
                if (transferJob === self) {
                    _state.update { it.copy(isTransferring = false, currentSpeed = 0) }
                    TransferService.stop(getApplication())
                }
            }
        }
    }

    /**
     * 单次遍历目标目录：
     * 1) 当 [deleteParts]=true 时删除遗留的半成品（[PART_PREFIX] 开头的临时文件，上次崩溃/被杀留下）；
     * 2) 返回完整文件的 显示名->大小（字节，未知记 -1），用于"已存在则跳过"；
     * 3) 收集半成品文件信息到 parts 映射（原文件名 -> PartInfo），用于断点续传。
     * 合并清扫与列举，避免两次全目录扫描；正常完成的文件已改真名，不会被误删。
     *
     * @param deleteParts true=清空半成品（App 启动/新队列）, false=保留半成品供续传（队列启动重试）
     * @return Pair(完整文件映射, 半成品映射: 去掉前缀后的原文件名 -> PartInfo)
     */
    private fun sweepAndListExisting(
        treeUri: Uri,
        deleteParts: Boolean = true
    ): Pair<MutableMap<String, Long>, Map<String, PartInfo>> {
        val map = HashMap<String, Long>()
        val parts = HashMap<String, PartInfo>()
        try {
            val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
                treeUri,
                DocumentsContract.getTreeDocumentId(treeUri)
            )
            contentResolver.query(
                childrenUri,
                arrayOf(
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                    DocumentsContract.Document.COLUMN_SIZE,
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID
                ),
                null, null, null
            )?.use { c ->
                val nameIdx = c.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                val sizeIdx = c.getColumnIndex(DocumentsContract.Document.COLUMN_SIZE)
                val idIdx = c.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                if (nameIdx >= 0) {
                    while (c.moveToNext()) {
                        val name = c.getString(nameIdx) ?: continue
                        if (name.startsWith(PART_PREFIX)) {
                            if (deleteParts && idIdx >= 0) {
                                val docId = c.getString(idIdx) ?: continue
                                try {
                                    DocumentsContract.deleteDocument(
                                        contentResolver,
                                        DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)
                                    )
                                } catch (_: Exception) {}
                            } else if (!deleteParts && idIdx >= 0) {
                                // 续传模式：保留半成品，解析出身份令牌与原文件名（按首个下划线切分）。
                                val docId = c.getString(idIdx) ?: continue
                                val size = if (sizeIdx >= 0 && !c.isNull(sizeIdx)) c.getLong(sizeIdx) else 0L
                                val afterPrefix = name.removePrefix(PART_PREFIX)
                                val sep = afterPrefix.indexOf('_')
                                if (sep > 0) {
                                    val token = afterPrefix.substring(0, sep)
                                    val origName = afterPrefix.substring(sep + 1)
                                    if (origName.isNotEmpty()) {
                                        parts[origName] = PartInfo(
                                            uri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId),
                                            size = size, token = token
                                        )
                                    }
                                }
                                // sep<=0：旧格式/异常半成品名，不记录（App 启动 init sweep 会清掉）。
                            }
                        } else {
                            val size = if (sizeIdx >= 0 && !c.isNull(sizeIdx)) c.getLong(sizeIdx) else -1L
                            map[name] = size
                        }
                    }
                }
            }
        } catch (_: Exception) {}
        return map to parts
    }

    /**
     * 删除下载失败/取消留下的半成品文件，忽略删除失败。走 IO 线程（Binder + 磁盘）；
     * NonCancellable 保证取消路径（协程已被 cancel）也能完成清理。
     */
    private suspend fun deleteQuietly(uri: Uri?) {
        if (uri == null) return
        withContext(NonCancellable + Dispatchers.IO) {
            try {
                DocumentsContract.deleteDocument(contentResolver, uri)
            } catch (_: Exception) {}
        }
    }

    /** 改名；失败（如目标名已存在、部分 provider 返回 null）返回 null。走 IO 线程。 */
    private suspend fun renameQuietly(uri: Uri, newName: String): Uri? = withContext(Dispatchers.IO) {
        try {
            DocumentsContract.renameDocument(contentResolver, uri, newName)
        } catch (_: Exception) {
            null
        }
    }

    /**
     * 鸿蒙回退：把下载完好的临时文件【复制】成名为 [name] 的正式文件（renameDocument
     * 损坏的设备用，见 [renameBroken]）。复制后按 [expectedBytes] 校验字节数，
     * 不完整/失败则删除半成品正式文件并返回 null。
     * 权衡说明：改名是原子操作，复制不是——进程在复制中途被杀会留下残缺真名文件
     *（本地磁盘拷贝很快，窗口极小，且残缺文件因大小不符不会被"已存在跳过"误放行，
     * 重传会以 " (n)" 副本落盘自愈）。仅在改名损坏的设备上承担此取舍。
     * 成功返回正式文件 Uri；临时文件的删除由调用方负责。走 IO 线程。
     */
    private suspend fun copyAsFallback(
        parentDocUri: Uri,
        tempUri: Uri,
        name: String,
        mime: String,
        expectedBytes: Long
    ): Result<Uri> = withContext(Dispatchers.IO) {
        var created: Uri? = null
        try {
            created = DocumentsContract.createDocument(contentResolver, parentDocUri, mime, name)
                ?: return@withContext Result.failure(Exception(str(R.string.error_create_file)))
            val copiedBytes = contentResolver.openInputStream(tempUri)!!.use { input ->
                java.io.BufferedOutputStream(
                    contentResolver.openOutputStream(created)!!, 1024 * 1024
                ).use { output ->
                    input.copyTo(output, 1024 * 1024)
                }
            }
            if (copiedBytes != expectedBytes) throw Exception(str(R.string.error_copy_incomplete, copiedBytes, expectedBytes))
            Result.success(created)
        } catch (e: CancellationException) {
            // 取消（App 退出）不吞：清掉半成品后向上传播，维持"取消必须传播"的全局约定。
            created?.let {
                try { DocumentsContract.deleteDocument(contentResolver, it) } catch (_: Exception) {}
            }
            throw e
        } catch (e: Exception) {
            if (BuildConfig.DEBUG) {
                android.util.Log.w(TAG, "copyAsFallback failed: ${e.message}")
            }
            created?.let {
                try { DocumentsContract.deleteDocument(contentResolver, it) } catch (_: Exception) {}
            }
            // 带原因返回：界面把它拼进"保存失败：…"，出错自带诊断信息，免大范围排查。
            Result.failure(e)
        }
    }

    /** 查询 SAF 文档的实际显示名（provider 重名时会静默改名，落盘名≠请求名）。走 IO 线程。 */
    private suspend fun displayNameOf(uri: Uri): String? = withContext(Dispatchers.IO) {
        try {
            contentResolver.query(
                uri, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null
            )?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
        } catch (_: Exception) {
            null
        }
    }

    /** 剥掉重名副本后缀："DSC_0001 (2).NEF" -> "DSC_0001.NEF"，用于与相机文件名归一化匹配。 */
    private fun baseName(name: String): String = name.replace(COPY_SUFFIX_REGEX, "")

    /** 生成重名副本名："DSC_0001.NEF" + 2 -> "DSC_0001 (2).NEF"；无扩展名则直接追加。 */
    private fun suffixedName(name: String, n: Int): String {
        val dot = name.lastIndexOf('.')
        return if (dot <= 0) "$name ($n)" else "${name.substring(0, dot)} ($n)${name.substring(dot)}"
    }

    /** 按 handle 就地更新任务；handle 不存在时保持列表不变。用 update 保证跨线程原子读改写。 */
    private fun updateTask(handle: Int, transform: (TransferTask) -> TransferTask) {
        _state.update { state ->
            state.copy(tasks = state.tasks.map { if (it.file.handle == handle) transform(it) else it })
        }
    }

    private inline fun log(message: () -> String) {
        if (BuildConfig.DEBUG) android.util.Log.d(TAG, message())
    }

    private fun getMimeType(fileName: String): String {
        return when {
            fileName.endsWith(".jpg", true) -> "image/jpeg"
            fileName.endsWith(".nef", true) -> "image/x-nikon-nef"
            fileName.endsWith(".mov", true) -> "video/quicktime"
            fileName.endsWith(".mp4", true) -> "video/mp4"
            else -> "application/octet-stream"
        }
    }

    /**
     * 撤下所有等待中的任务（WAITING→CANCELLED），队列协程不会再开始它们；
     * 正在传输的文件让它自然传完——中途打断需要发 PTP/IP Cancel 包或直接断开连接，
     * 实测两者都会让相机挂起会话甚至关闭 Wi-Fi，代价远高于传完当前文件。
     * 队列协程发现没有 WAITING 任务后自然收尾（isTransferring 复位、前台服务停止）。
     * "清空队列"的第一步：先撤下，UI 播完移除动画后再逐个 [removeTask]。
     */
    fun withdrawPending() {
        _state.update { state ->
            state.copy(
                tasks = state.tasks.map {
                    if (it.status == TransferStatus.WAITING) {
                        it.copy(status = TransferStatus.CANCELLED, speed = 0)
                    } else it
                }
            )
        }
    }

    /** 撤下单个等待中的任务（仅 WAITING→CANCELLED）：移除动画播放期间队列不得开始传它。 */
    fun withdrawTask(handle: Int) {
        _state.update { state ->
            state.copy(
                tasks = state.tasks.map {
                    if (it.file.handle == handle && it.status == TransferStatus.WAITING) {
                        it.copy(status = TransferStatus.CANCELLED, speed = 0)
                    } else it
                }
            )
        }
    }

    /**
     * 清空收尾：一次性移除所有已终结的任务（CANCELLED/COMPLETED/FAILED）。
     * "清空队列"的兜底——LazyColumn 只组合可见卡片，屏幕外的卡没有条目协程替它做
     * "动画后移除"，由本方法在可见卡片收合动画播完后统一清掉。
     * 与 [removeTask] 同规则：TRANSFERING/WAITING 一律保留。
     */
    fun removeCleared() {
        _state.update { state ->
            state.copy(
                tasks = state.tasks.filter {
                    it.status == TransferStatus.TRANSFERING || it.status == TransferStatus.WAITING
                }
            )
        }
    }

    /**
     * 把任务卡片从队列移除（移除动画结束后调用），返回是否真的移除了。
     * 拒绝移除 TRANSFERING（正在传输）与 WAITING（动画期间被"重试"重置回等待，
     * 说明用户想要它了）——两种竞态下调用方把卡片弹回原高即可。
     * 合法移除路径上任务必为 CANCELLED/COMPLETED/FAILED（等待中的在标记时已 withdraw）。
     */
    fun removeTask(handle: Int): Boolean {
        var removed = false
        _state.update { state ->
            val kept = state.tasks.filterNot {
                it.file.handle == handle &&
                        it.status != TransferStatus.TRANSFERING &&
                        it.status != TransferStatus.WAITING
            }
            removed = kept.size != state.tasks.size
            state.copy(tasks = kept)
        }
        return removed
    }

    /**
     * 重试失败/取消的任务：从队列移除后经 [addToQueue] 重新加入——与用户重新点选这些
     * 文件完全同一条路径（同样的去重、排队与启动时机），重试没有任何特殊逻辑。
     */
    fun retryFailed(cameraProvider: () -> NikonCamera?) {
        if (_state.value.transferDirUri == null) return
        val retry = _state.value.tasks.filter {
            it.status == TransferStatus.FAILED || it.status == TransferStatus.CANCELLED
        }
        if (retry.isEmpty()) return
        val handles = retry.mapTo(HashSet()) { it.file.handle }
        _state.update { s -> s.copy(tasks = s.tasks.filterNot { it.file.handle in handles }) }
        addToQueue(retry.map { it.file }, cameraProvider)
    }

    /** 同 [retryFailed]：单个任务移除后按新任务重新入队。 */
    fun retrySingleTask(handle: Int, cameraProvider: () -> NikonCamera?) {
        val task = _state.value.tasks.firstOrNull { it.file.handle == handle } ?: return
        if (task.status != TransferStatus.FAILED && task.status != TransferStatus.CANCELLED) return
        if (_state.value.transferDirUri == null) return
        _state.update { s -> s.copy(tasks = s.tasks.filterNot { it.file.handle == handle }) }
        addToQueue(listOf(task.file), cameraProvider)
    }

    override fun onCleared() {
        super.onCleared()
        transferJob?.cancel()
        // 兜底停止前台服务，防止 VM 销毁后通知残留。
        TransferService.stop(getApplication())
    }
}
