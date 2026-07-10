package com.nikon.transfer.viewmodel

import android.app.Application
import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.nikon.transfer.BuildConfig
import com.nikon.transfer.protocol.NikonCamera
import com.nikon.transfer.protocol.PtpConstants
import com.nikon.transfer.service.TransferService
import com.nikon.transfer.ui.theme.ThemeMode
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
    val downloadMBps: Float = 0f
)

data class TransferState(
    val tasks: List<TransferTask> = emptyList(),
    val isTransferring: Boolean = false,
    val currentSpeed: Long = 0,
    val transferDirUri: String? = null,
    val thumbnailColumns: Int = 3,
    // 触感反馈开关：默认关闭，用户开启后持久化，下次启动保持。
    val hapticsEnabled: Boolean = false,
    // 屏幕常亮（默认开启）：应用在前台时不熄屏——熄屏后系统会冻结进程/让 Wi-Fi 打盹，
    // 相机连接容易断；代价是手机一直亮屏。
    val keepScreenOn: Boolean = true,
    // 主题模式：默认跟随系统深浅色，可在设置里固定深色/浅色。
    val themeMode: ThemeMode = ThemeMode.SYSTEM,
    // 照片类型筛选（归一化扩展名，如 ".jpg"）：null = 全部（不过滤，新类型也放行）。
    // 持久化跨会话生效；设备上没有所选类型时列表自然为空，不做特殊处理。
    val filterExtensions: Set<String>? = null
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
    private val prefs = application.getSharedPreferences("nikon_transfer", Context.MODE_PRIVATE)
    private val contentResolver = application.contentResolver

    // 鸿蒙适配：部分华为/荣耀设备的 DocumentsProvider renameDocument 损坏（无论目标名
    // 是否空闲都失败），下载完好的临时文件改不了正式名 → 每张都"保存失败"。
    // 首次确认损坏后置位，本会话后续文件跳过改名直接走"复制为正式文件"回退路径，
    // 不再每个文件白试上百次改名。安卓正常设备永远不会置位，行为零变化。
    private var renameBroken = false

    private companion object {
        const val TAG = "NikonTransfer"
        // 未完成文件的临时名前缀（带前导点，在相册中隐藏）。真正文件名只在下载完整后才出现。
        const val PART_PREFIX = ".nkpart_"
        // 重名副本后缀（"DSC_0001 (1).NEF" 中的 " (1)"），用于剥离/生成。
        val COPY_SUFFIX_REGEX = Regex(""" \(\d+\)(?=\.[^.]*$|$)""")
    }

    init {
        val dir = prefs.getString("transfer_dir", null)
        _state.update {
            it.copy(
                transferDirUri = dir,
                thumbnailColumns = prefs.getInt("thumbnail_columns", 3).coerceIn(1, 4),
                hapticsEnabled = prefs.getBoolean("haptics_enabled", false),
                keepScreenOn = prefs.getBoolean("keep_screen_on", true),
                themeMode = prefs.getString("theme_mode", null)
                    ?.let { m -> ThemeMode.entries.firstOrNull { e -> e.name == m } }
                    ?: ThemeMode.SYSTEM,
                // getStringSet 返回的实例不可直接持有（SharedPreferences 约定），拷贝一份。
                filterExtensions = prefs.getStringSet("filter_exts", null)?.toSet()
            )
        }
        // 开 App 时清扫上次崩溃/被杀留下的半成品（.nkpart_ 临时文件）。
        if (dir != null) {
            viewModelScope.launch(Dispatchers.IO) {
                try { sweepAndListExisting(Uri.parse(dir)) } catch (_: Exception) {}
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

    /** 照片类型筛选；null = 全部。持久化，跨会话与跨设备连接生效。 */
    fun setFilterExtensions(exts: Set<String>?) {
        prefs.edit().apply {
            if (exts == null) remove("filter_exts") else putStringSet("filter_exts", exts)
        }.apply()
        _state.update { it.copy(filterExtensions = exts) }
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
                    _state.update { s ->
                        s.copy(
                            transferDirUri = null,
                            tasks = s.tasks.map {
                                if (it.status == TransferStatus.WAITING) {
                                    it.copy(status = TransferStatus.FAILED, error = "传输目录已失效，请重新选择")
                                } else it
                            }
                        )
                    }
                    return@launch   // finally 负责复位 isTransferring（前台服务尚未启动）
                }

                // 单次遍历：清扫遗留半成品(.nkpart_) + 建立"已存在(名称->大小)"去重表。
                val existing = withContext(Dispatchers.IO) { sweepAndListExisting(uri) }
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

                    // 每个任务开始时现取相机实例：中途掉线重连后，后续任务用的是新连接，
                    // 而不是队列启动时捕获的旧实例（旧实例 socket 已死，只会全部快速失败）。
                    val camera = cameraProvider()
                    if (camera == null) {
                        updateTask(handle) {
                            it.copy(status = TransferStatus.FAILED, error = "相机未连接", speed = 0)
                        }
                        continue
                    }

                    updateTask(handle) { it.copy(status = TransferStatus.TRANSFERING) }
                    log { "DL_BEGIN: ${task.file.fileName} handle=$handle size=${task.file.size}" }

                    // 首个真正要下载的文件才拉起前台服务（全部命中"已存在"时不必启动，避免通知闪一下）。
                    if (!serviceStarted) {
                        TransferService.start(getApplication())
                        serviceStarted = true
                    }

                    // 追踪已创建的文档，失败/取消时删除半成品，避免残留与重试时产生重名副本。
                    var fileDocUri: Uri? = null
                    try {
                        // SAF 的建文件/开流/关闭冲刷都是跨进程 Binder + 磁盘 IO，放 IO 线程，
                        // 不在主线程随每个文件抖一下（状态更新经 StateFlow.update，线程安全）。
                        val result = withContext(Dispatchers.IO) {
                            // 写入临时名 .nkpart_原名（扩展名保留，与 mime 匹配，避免 SAF 追加扩展名）。
                            // 下载完整后再改名成真正文件名——崩溃/被杀只会留下 .nkpart_ 半成品，绝不出现残缺的真名文件。
                            val createdUri = DocumentsContract.createDocument(
                                contentResolver,
                                docUri,
                                getMimeType(task.file.fileName),
                                PART_PREFIX + task.file.fileName
                            ) ?: throw Exception("无法创建文件")
                            fileDocUri = createdUri

                            val outputStream = contentResolver.openOutputStream(createdUri)
                                ?: throw Exception("无法打开文件")

                            // 用大缓冲包裹 SAF 输出流，把零散的写批量化，减少 ContentProvider 往返。
                            // 缺了它，每个 PTP-IP 数据包都要跨 Binder 写一次 SAF，吞吐直接腰斩（2M/s→<1M/s）。
                            java.io.BufferedOutputStream(outputStream, 1024 * 1024).use { out ->
                                camera.downloadToFile(handle, out) { progress ->
                                    val speed = if (progress.elapsed > 0) {
                                        (progress.downloaded / progress.elapsed).toLong()
                                    } else 0
                                    // 单次原子更新：同时写当前速度与该任务进度，避免每个进度 tick
                                    // 触发两次 StateFlow 发射 / 两次全量列表拷贝（5Hz 下累积可观）。
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
                                }
                            }
                        }
                        // withContext 正常返回则临时文件必已创建（否则内部已抛异常）。
                        val createdUri = checkNotNull(fileDocUri)

                        result.fold(
                            onSuccess = { stats ->
                                // 下载完整 → 把临时名改成真正文件名（相机上报的文件名即为准）。
                                val finalName = task.file.fileName
                                var savedName = finalName
                                var renamedUri = if (renameBroken) null else renameQuietly(createdUri, finalName)
                                if (renamedUri == null && !renameBroken) {
                                    // 目标名已被占用（历史残缺文件 / 相机跨文件夹 DSC 编号回卷重名）。
                                    // 绝不覆盖已有文件，也绝不让任务陷入"每次重下、每次改名失败"的
                                    // 死循环：落为 "名字 (n).扩展名" 副本。
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
                                    // 鸿蒙回退路径：连不冲突的候选名都改不动 = 该设备 renameDocument
                                    // 损坏（而非重名问题），把临时文件【复制】成正式文件再删临时。
                                    // 多一次本地磁盘拷贝，仅发生在改名损坏的设备上。
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
                                        renameBroken = true   // 记住：本会话后续文件直接走复制
                                        deleteQuietly(createdUri)   // 临时文件使命完成
                                        // provider 重名时会静默改名（如自动加后缀），
                                        // 去重簿记以实际落盘名为准。
                                        savedName = displayNameOf(copiedUri) ?: copyName
                                        renamedUri = copiedUri
                                        log { "DL_SAVE via copy fallback: $savedName (rename broken)" }
                                    } else {
                                        saveError = copied.exceptionOrNull()
                                    }
                                }
                                if (renamedUri != null) {
                                    // 供后续任务与跨会话去重（副本按归一化名归档）。记真实落盘字节数
                                    // 而非 ObjectInfo 大小——>4GB 对象后者只是哨兵值，与磁盘对不上。
                                    existing[savedName] = stats.bytes
                                    existingSizes.getOrPut(baseName(savedName)) { HashSet() }.add(stats.bytes)
                                    updateTask(handle) {
                                        it.copy(
                                            status = TransferStatus.COMPLETED, progress = 1f,
                                            downloaded = stats.bytes, speed = 0,
                                            downloadMBps = stats.mbps
                                        )
                                    }
                                } else {
                                    // 改名与复制均失败：删掉临时文件并标记失败让用户重试，
                                    // 避免完整数据以 .nkpart_ 名残留后被后续 sweep 静默删除。
                                    // 错误文案带上具体原因——用户报障时截图即含一手线索。
                                    deleteQuietly(createdUri)
                                    val reason = when {
                                        saveError is java.io.FileNotFoundException ->
                                            "传输目录已失效，请重新选择"
                                        saveError?.message != null -> saveError.message
                                        else -> "系统拒绝改名与复制"
                                    }
                                    updateTask(handle) {
                                        it.copy(status = TransferStatus.FAILED, error = "保存失败：$reason", speed = 0)
                                    }
                                }
                            },
                            onFailure = { e ->
                                // 掉线也当普通失败处理（相机断开后会省电关 Wi-Fi，无法即时续传）；
                                // 重连后由用户点"重试全部"重新下载。
                                deleteQuietly(fileDocUri)
                                updateTask(handle) {
                                    it.copy(status = TransferStatus.FAILED, error = e.message ?: "传输失败", speed = 0)
                                }
                            }
                        )
                    } catch (e: CancellationException) {
                        // 协程取消只发生在 ViewModel 销毁（App 退出）时——界面上的"停止"
                        // 不再取消协程（正在传的文件自然传完，见 withdrawPending）。
                        // 此处【不】就地删除半成品：清理要等协议层收尾后才执行，时序难保证，
                        // 半成品交给每次队列启动/App 启动的 sweep 统一清扫
                        //（.nkpart_ 前缀带前导点，相册中本就不可见）。
                        throw e   // 取消须向上传播
                    } catch (e: Exception) {
                        deleteQuietly(fileDocUri)
                        if (BuildConfig.DEBUG) {
                            android.util.Log.e(TAG, "DL_FAIL: ${task.file.fileName} - ${e.javaClass.simpleName}: ${e.message}", e)
                        }
                        // 目录中途失效（如传输期间被文件管理器删除）：翻译成人话，
                        // 而不是把 SAF 的 "Missing file for primary:..." 原样示人。
                        val msg = if (e is java.io.FileNotFoundException) {
                            "传输目录已失效，请重新选择"
                        } else {
                            e.message ?: "传输失败"
                        }
                        updateTask(handle) {
                            it.copy(status = TransferStatus.FAILED, error = msg, speed = 0)
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
     * 1) 删除遗留的半成品（[PART_PREFIX] 开头的临时文件，上次崩溃/被杀留下）；
     * 2) 返回其余"完整文件"的 显示名->大小（字节，未知记 -1），用于"已存在则跳过"。
     * 合并清扫与列举，避免两次全目录扫描；正常完成的文件已改真名，不会被误删。
     */
    private fun sweepAndListExisting(treeUri: Uri): MutableMap<String, Long> {
        val map = HashMap<String, Long>()
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
                            if (idIdx >= 0) {
                                val docId = c.getString(idIdx) ?: continue
                                try {
                                    DocumentsContract.deleteDocument(
                                        contentResolver,
                                        DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)
                                    )
                                } catch (_: Exception) {}
                            }
                        } else {
                            val size = if (sizeIdx >= 0 && !c.isNull(sizeIdx)) c.getLong(sizeIdx) else -1L
                            map[name] = size
                        }
                    }
                }
            }
        } catch (_: Exception) {}
        return map
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
                ?: return@withContext Result.failure(Exception("无法创建文件"))
            val copiedBytes = contentResolver.openInputStream(tempUri)!!.use { input ->
                java.io.BufferedOutputStream(
                    contentResolver.openOutputStream(created)!!, 1024 * 1024
                ).use { output ->
                    input.copyTo(output, 1024 * 1024)
                }
            }
            if (copiedBytes != expectedBytes) throw Exception("复制不完整 $copiedBytes/$expectedBytes")
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
