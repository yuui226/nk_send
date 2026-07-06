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
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

enum class TransferStatus {
    WAITING, TRANSFERING, COMPLETED, FAILED, CANCELLED
}

data class TransferTask(
    val file: NikonCamera.FileInfo,
    val status: TransferStatus = TransferStatus.WAITING,
    val progress: Float = 0f,
    val speed: Long = 0,
    val downloaded: Long = 0,
    val error: String? = null
)

data class TransferState(
    val tasks: List<TransferTask> = emptyList(),
    val isTransferring: Boolean = false,
    val currentSpeed: Long = 0,
    val transferDirUri: String? = null
)

class TransferViewModel(application: Application) : AndroidViewModel(application) {
    private val _state = MutableStateFlow(TransferState())
    val state: StateFlow<TransferState> = _state.asStateFlow()

    private var transferJob: Job? = null
    private val prefs = application.getSharedPreferences("nikon_transfer", Context.MODE_PRIVATE)
    private val contentResolver = application.contentResolver

    private companion object {
        const val TAG = "NikonTransfer"
    }

    init {
        _state.value = _state.value.copy(
            transferDirUri = prefs.getString("transfer_dir", null)
        )
    }

    fun setTransferDirUri(uri: Uri) {
        contentResolver.takePersistableUriPermission(
            uri,
            android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    android.content.Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        )
        prefs.edit().putString("transfer_dir", uri.toString()).apply()
        _state.value = _state.value.copy(transferDirUri = uri.toString())
    }

    fun addToQueue(files: List<NikonCamera.FileInfo>, camera: NikonCamera) {
        val dirUri = _state.value.transferDirUri
        if (dirUri == null) {
            // 追加失败任务，不覆盖已有
            val errorTasks = files.map {
                TransferTask(file = it, status = TransferStatus.FAILED, error = "未设置传输目录")
            }
            _state.value = _state.value.copy(tasks = _state.value.tasks + errorTasks)
            return
        }

        val newTasks = files.map { TransferTask(file = it) }
        _state.value = _state.value.copy(tasks = _state.value.tasks + newTasks)

        if (!_state.value.isTransferring) {
            processQueue(dirUri, camera)
        }
    }

    private fun processQueue(dirUri: String, camera: NikonCamera) {
        if (transferJob?.isActive == true) return

        transferJob = viewModelScope.launch {
            _state.value = _state.value.copy(isTransferring = true)
            // 前台服务 + 唤醒锁，保证锁屏/切后台时传输不被系统杀死。
            TransferService.start(getApplication())

            try {
                val uri = Uri.parse(dirUri)
                val docUri = DocumentsContract.buildDocumentUriUsingTree(
                    uri,
                    DocumentsContract.getTreeDocumentId(uri)
                )

                while (true) {
                    // 以 handle（稳定唯一键）定位任务，避免 clearCompleted 等操作导致下标串位。
                    val task = _state.value.tasks.firstOrNull { it.status == TransferStatus.WAITING } ?: break
                    val handle = task.file.handle
                    updateTask(handle) { it.copy(status = TransferStatus.TRANSFERING) }
                    log { "DL_BEGIN: ${task.file.fileName} handle=$handle size=${task.file.size}" }

                    try {
                        val fileDocUri = DocumentsContract.createDocument(
                            contentResolver,
                            docUri,
                            getMimeType(task.file.fileName),
                            task.file.fileName
                        ) ?: throw Exception("无法创建文件")

                        val outputStream = contentResolver.openOutputStream(fileDocUri)
                            ?: throw Exception("无法打开文件")

                        val result = outputStream.use { out ->
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
                                _state.value = _state.value.copy(currentSpeed = speed)
                            }
                        }

                        result.fold(
                            onSuccess = { (size, detectedExt) ->
                                if (task.file.extension == ".bin" && detectedExt != null && detectedExt != ".bin") {
                                    try {
                                        val newName = task.file.fileName.substringBeforeLast('.') + detectedExt
                                        DocumentsContract.renameDocument(contentResolver, fileDocUri, newName)
                                    } catch (_: Exception) {}
                                }
                                updateTask(handle) {
                                    it.copy(status = TransferStatus.COMPLETED, progress = 1f, downloaded = size, speed = 0)
                                }
                            },
                            onFailure = { e ->
                                updateTask(handle) {
                                    it.copy(status = TransferStatus.FAILED, error = e.message ?: "传输失败", speed = 0)
                                }
                            }
                        )
                    } catch (e: CancellationException) {
                        throw e   // 取消须向上传播，交由 cancelTransfer 统一置为 CANCELLED
                    } catch (e: Exception) {
                        if (BuildConfig.DEBUG) {
                            android.util.Log.e(TAG, "DL_FAIL: ${task.file.fileName} - ${e.javaClass.simpleName}: ${e.message}", e)
                        }
                        updateTask(handle) {
                            it.copy(status = TransferStatus.FAILED, error = e.message ?: "传输失败", speed = 0)
                        }
                    }
                }
            } finally {
                _state.value = _state.value.copy(isTransferring = false, currentSpeed = 0)
                TransferService.stop(getApplication())
            }
        }
    }

    /** 按 handle 就地更新任务；handle 不存在时保持列表不变。 */
    private fun updateTask(handle: Int, transform: (TransferTask) -> TransferTask) {
        _state.value = _state.value.copy(
            tasks = _state.value.tasks.map { if (it.file.handle == handle) transform(it) else it }
        )
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
        _state.value = _state.value.copy(
            isTransferring = false,
            currentSpeed = 0,
            tasks = _state.value.tasks.map {
                if (it.status == TransferStatus.WAITING || it.status == TransferStatus.TRANSFERING) {
                    it.copy(status = TransferStatus.CANCELLED, speed = 0)
                } else it
            }
        )
    }

    fun retryFailed(camera: NikonCamera) {
        val tasks = _state.value.tasks
        val hasFailed = tasks.any { it.status == TransferStatus.FAILED || it.status == TransferStatus.CANCELLED }
        if (!hasFailed) return

        _state.value = _state.value.copy(
            tasks = tasks.map {
                if (it.status == TransferStatus.FAILED || it.status == TransferStatus.CANCELLED) {
                    it.copy(status = TransferStatus.WAITING, progress = 0f, downloaded = 0, error = null, speed = 0)
                } else it
            }
        )

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
        _state.value = _state.value.copy(
            tasks = _state.value.tasks.filter {
                it.status != TransferStatus.COMPLETED && it.status != TransferStatus.CANCELLED && it.status != TransferStatus.FAILED
            }
        )
    }

    override fun onCleared() {
        super.onCleared()
        transferJob?.cancel()
        // 兜底停止前台服务，防止 VM 销毁后通知残留。
        TransferService.stop(getApplication())
    }
}
