package com.nikon.transfer.viewmodel

import android.app.Application
import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.nikon.transfer.BuildConfig
import com.nikon.transfer.protocol.NikonCamera
import com.nikon.transfer.service.TransferService
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
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
    val skipped: Boolean = false   // 目标目录已存在同名文件而跳过
)

data class TransferState(
    val tasks: List<TransferTask> = emptyList(),
    val isTransferring: Boolean = false,
    val currentSpeed: Long = 0,
    val transferDirUri: String? = null,
    val thumbnailMode: Boolean = false,
    val thumbnailColumns: Int = 3
)

class TransferViewModel(application: Application) : AndroidViewModel(application) {
    private val _state = MutableStateFlow(TransferState())
    val state: StateFlow<TransferState> = _state.asStateFlow()

    private var transferJob: Job? = null
    private val prefs = application.getSharedPreferences("nikon_transfer", Context.MODE_PRIVATE)
    private val contentResolver = application.contentResolver

    private companion object {
        const val TAG = "NikonTransfer"
        // 未完成文件的临时名前缀（带前导点，在相册中隐藏）。真正文件名只在下载完整后才出现。
        const val PART_PREFIX = ".nkpart_"
    }

    init {
        val dir = prefs.getString("transfer_dir", null)
        _state.update {
            it.copy(
                transferDirUri = dir,
                thumbnailMode = prefs.getBoolean("thumbnail_mode", false),
                thumbnailColumns = prefs.getInt("thumbnail_columns", 3).coerceIn(1, 4)
            )
        }
        // 开 App 时清扫上次崩溃/被杀留下的半成品（.nkpart_ 临时文件）。
        if (dir != null) {
            viewModelScope.launch(Dispatchers.IO) {
                try { sweepAndListExisting(Uri.parse(dir)) } catch (_: Exception) {}
            }
        }
    }

    fun setThumbnailMode(enabled: Boolean) {
        prefs.edit().putBoolean("thumbnail_mode", enabled).apply()
        _state.update { it.copy(thumbnailMode = enabled) }
    }

    fun setThumbnailColumns(columns: Int) {
        val c = columns.coerceIn(1, 4)
        prefs.edit().putInt("thumbnail_columns", c).apply()
        _state.update { it.copy(thumbnailColumns = c) }
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

    fun addToQueue(files: List<NikonCamera.FileInfo>, camera: NikonCamera) {
        // 未设置传输目录时禁止入队（UI 层会把用户引导到设置页）。
        val dirUri = _state.value.transferDirUri ?: return

        val newTasks = files.map { TransferTask(file = it) }
        _state.update { it.copy(tasks = it.tasks + newTasks) }

        if (!_state.value.isTransferring) {
            processQueue(dirUri, camera)
        }
    }

    private fun processQueue(dirUri: String, camera: NikonCamera) {
        if (transferJob?.isActive == true) return

        transferJob = viewModelScope.launch {
            _state.update { it.copy(isTransferring = true) }
            var serviceStarted = false

            try {
                val uri = Uri.parse(dirUri)
                val docUri = DocumentsContract.buildDocumentUriUsingTree(
                    uri,
                    DocumentsContract.getTreeDocumentId(uri)
                )
                // 单次遍历：清扫遗留半成品(.nkpart_) + 建立"已存在(名称->大小)"去重表。
                val existing = withContext(Dispatchers.IO) { sweepAndListExisting(uri) }

                while (true) {
                    // 以 handle（稳定唯一键）定位任务，避免 clearCompleted 等操作导致下标串位。
                    val task = _state.value.tasks.firstOrNull { it.status == TransferStatus.WAITING } ?: break
                    val handle = task.file.handle

                    // 目标目录已存在同名文件（大小一致或大小未知）→ 跳过，不重复下载。
                    val existingSize = existing[task.file.fileName]
                    if (existingSize != null && (existingSize == task.file.size || existingSize < 0L)) {
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

                    updateTask(handle) { it.copy(status = TransferStatus.TRANSFERING) }
                    log { "DL_BEGIN: ${task.file.fileName} handle=$handle size=${task.file.size}" }

                    // 首个真正要下载的文件才拉起前台服务（全部命中"已存在"时不必启动，避免通知闪一下）。
                    if (!serviceStarted) {
                        TransferService.start(getApplication())
                        serviceStarted = true
                    }

                    // 追踪已创建的文档，失败/取消时删除半成品，避免残留与重试时产生重名副本。
                    var fileDocUri: Uri? = null
                    // 连接断开导致的失败：把任务放回等待队列并暂停整个队列，等重连后自动继续。
                    var pausedForDisconnect = false
                    try {
                        // 写入临时名 .nkpart_原名（扩展名保留，与 mime 匹配，避免 SAF 追加扩展名）。
                        // 下载完整后再改名成真正文件名——崩溃/被杀只会留下 .nkpart_ 半成品，绝不出现残缺的真名文件。
                        fileDocUri = DocumentsContract.createDocument(
                            contentResolver,
                            docUri,
                            getMimeType(task.file.fileName),
                            PART_PREFIX + task.file.fileName
                        ) ?: throw Exception("无法创建文件")

                        val outputStream = contentResolver.openOutputStream(fileDocUri)
                            ?: throw Exception("无法打开文件")

                        // 用大缓冲包裹 SAF 输出流，把零散的写批量化，减少 ContentProvider 往返。
                        val result = java.io.BufferedOutputStream(outputStream, 1024 * 1024).use { out ->
                            camera.downloadToFile(handle, out) { progress ->
                                val speed = if (progress.elapsed > 0) {
                                    (progress.downloaded / progress.elapsed).toLong()
                                } else 0
                                updateTask(handle) { t ->
                                    if (t.status == TransferStatus.TRANSFERING) {
                                        t.copy(
                                            progress = if (progress.total > 0) {
                                                progress.downloaded.toFloat() / progress.total
                                            } else 0f,
                                            downloaded = progress.downloaded,
                                            speed = speed
                                        )
                                    } else t
                                }
                                _state.update { it.copy(currentSpeed = speed) }
                            }
                        }

                        result.fold(
                            onSuccess = { size ->
                                // 下载完整 → 把临时名改成真正文件名（相机上报的文件名即为准）。
                                val finalName = task.file.fileName
                                val renamedUri = try {
                                    DocumentsContract.renameDocument(contentResolver, fileDocUri, finalName)
                                } catch (_: Exception) { null }
                                if (renamedUri != null) {
                                    existing[finalName] = task.file.size   // 供后续任务去重
                                    updateTask(handle) {
                                        it.copy(status = TransferStatus.COMPLETED, progress = 1f, downloaded = size, speed = 0)
                                    }
                                } else {
                                    // 改名失败：删掉临时文件并标记失败让用户重试，
                                    // 避免完整数据以 .nkpart_ 名残留后被后续 sweep 静默删除。
                                    deleteQuietly(fileDocUri)
                                    updateTask(handle) {
                                        it.copy(status = TransferStatus.FAILED, error = "保存失败", speed = 0)
                                    }
                                }
                            },
                            onFailure = { e ->
                                deleteQuietly(fileDocUri)
                                if (isConnectionError(e)) {
                                    requeue(handle)
                                    pausedForDisconnect = true
                                } else {
                                    updateTask(handle) {
                                        it.copy(status = TransferStatus.FAILED, error = e.message ?: "传输失败", speed = 0)
                                    }
                                }
                            }
                        )
                    } catch (e: CancellationException) {
                        deleteQuietly(fileDocUri)   // 清理取消时的半成品文件
                        throw e                     // 取消须向上传播，交由 cancelTransfer 统一置为 CANCELLED
                    } catch (e: Exception) {
                        deleteQuietly(fileDocUri)
                        if (isConnectionError(e)) {
                            // 连接断开：放回队列并暂停，等待重连后自动继续
                            requeue(handle)
                            pausedForDisconnect = true
                        } else {
                            if (BuildConfig.DEBUG) {
                                android.util.Log.e(TAG, "DL_FAIL: ${task.file.fileName} - ${e.javaClass.simpleName}: ${e.message}", e)
                            }
                            updateTask(handle) {
                                it.copy(status = TransferStatus.FAILED, error = e.message ?: "传输失败", speed = 0)
                            }
                        }
                    }

                    // 连接断开：停止继续处理队列，剩余任务保持 WAITING，等重连后 onCameraConnected 续传。
                    if (pausedForDisconnect) break
                }
            } finally {
                _state.update { it.copy(isTransferring = false, currentSpeed = 0) }
                TransferService.stop(getApplication())
            }
        }
    }

    /** 把任务重置回等待状态（用于连接断开后续传）。 */
    private fun requeue(handle: Int) {
        updateTask(handle) {
            it.copy(status = TransferStatus.WAITING, progress = 0f, downloaded = 0, speed = 0, error = null)
        }
    }

    /**
     * 判断失败是否由连接断开引起。网络类异常（EOF/Socket 关闭/超时等）均为 IOException 子类；
     * 协议层错误（"传输失败: xxx"）是普通 Exception，按单文件失败处理。
     */
    private fun isConnectionError(e: Throwable): Boolean = e is java.io.IOException

    /**
     * 相机（重新）连接后调用：把中断残留的 TRANSFERING 复位为 WAITING，若队列仍有待传任务则自动续传。
     */
    fun onCameraConnected(camera: NikonCamera) {
        if (transferJob?.isActive == true) return
        _state.update { s ->
            s.copy(tasks = s.tasks.map {
                if (it.status == TransferStatus.TRANSFERING) {
                    it.copy(status = TransferStatus.WAITING, progress = 0f, downloaded = 0, speed = 0)
                } else it
            })
        }
        val dirUri = _state.value.transferDirUri ?: return
        if (_state.value.tasks.any { it.status == TransferStatus.WAITING }) {
            processQueue(dirUri, camera)
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

    /** 删除下载失败/取消留下的半成品文件，忽略删除失败。 */
    private fun deleteQuietly(uri: Uri?) {
        if (uri == null) return
        try {
            DocumentsContract.deleteDocument(contentResolver, uri)
        } catch (_: Exception) {}
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

    fun cancelTransfer() {
        transferJob?.cancel()
        transferJob = null
        _state.update { state ->
            state.copy(
                isTransferring = false,
                currentSpeed = 0,
                tasks = state.tasks.map {
                    if (it.status == TransferStatus.WAITING || it.status == TransferStatus.TRANSFERING) {
                        it.copy(status = TransferStatus.CANCELLED, speed = 0)
                    } else it
                }
            )
        }
    }

    fun retryFailed(camera: NikonCamera) {
        val hasFailed = _state.value.tasks.any { it.status == TransferStatus.FAILED || it.status == TransferStatus.CANCELLED }
        if (!hasFailed) return

        _state.update { state ->
            state.copy(
                tasks = state.tasks.map {
                    if (it.status == TransferStatus.FAILED || it.status == TransferStatus.CANCELLED) {
                        it.copy(status = TransferStatus.WAITING, progress = 0f, downloaded = 0, error = null, speed = 0)
                    } else it
                }
            )
        }

        val dirUri = _state.value.transferDirUri ?: return
        processQueue(dirUri, camera)
    }

    fun retrySingleTask(handle: Int, camera: NikonCamera) {
        val task = _state.value.tasks.firstOrNull { it.file.handle == handle } ?: return
        if (task.status != TransferStatus.FAILED && task.status != TransferStatus.CANCELLED) return

        updateTask(handle) {
            it.copy(status = TransferStatus.WAITING, progress = 0f, downloaded = 0, error = null, speed = 0)
        }

        val dirUri = _state.value.transferDirUri ?: return
        processQueue(dirUri, camera)
    }

    fun clearCompleted() {
        _state.update { state ->
            state.copy(
                tasks = state.tasks.filter {
                    it.status != TransferStatus.COMPLETED && it.status != TransferStatus.CANCELLED && it.status != TransferStatus.FAILED
                }
            )
        }
    }

    override fun onCleared() {
        super.onCleared()
        transferJob?.cancel()
        // 兜底停止前台服务，防止 VM 销毁后通知残留。
        TransferService.stop(getApplication())
    }
}
