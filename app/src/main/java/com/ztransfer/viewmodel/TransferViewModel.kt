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
import com.ztransfer.diagnostics.PhotoGenerationProbe
import com.ztransfer.effects.FAVORITE_FRAME_EFFECTS_PREFERENCE_KEY
import com.ztransfer.effects.FAVORITE_PHOTO_FILTERS_PREFERENCE_KEY
import com.ztransfer.effects.PHOTO_FILTER_INTENSITIES_PREFERENCE_KEY
import com.ztransfer.effects.FavoriteFrameWatermarkEffect
import com.ztransfer.effects.FavoritePhotoFilter
import com.ztransfer.effects.decodeFavoriteFrameEffects
import com.ztransfer.effects.decodeFavoritePhotoFilters
import com.ztransfer.effects.decodePhotoFilterIntensities
import com.ztransfer.effects.encodeFavoriteFrameEffects
import com.ztransfer.effects.encodeFavoritePhotoFilters
import com.ztransfer.effects.encodePhotoFilterIntensities
import com.ztransfer.frame.PhotoFrameDestination
import com.ztransfer.frame.PhotoFrameExporter
import com.ztransfer.frame.PhotoFrameMetadata
import com.ztransfer.frame.PhotoFrameMetadataSettings
import com.ztransfer.frame.PhotoFramePreset
import com.ztransfer.frame.PhotoFrameWatermark
import com.ztransfer.frame.PhotoFrameWatermarkColor
import com.ztransfer.frame.PhotoFrameWatermarkContent
import com.ztransfer.frame.PhotoFrameWatermarkEffect
import com.ztransfer.frame.PhotoFrameWatermarkFont
import com.ztransfer.frame.PhotoFrameWatermarkPosition
import com.ztransfer.frame.DEFAULT_PHOTO_FRAME_WATERMARK_OPACITY_PERCENT
import com.ztransfer.frame.DEFAULT_PHOTO_FRAME_WATERMARK_SIZE_PERCENT
import com.ztransfer.frame.PHOTO_FRAME_OUTPUT_DIRECTORY
import com.ztransfer.frame.PHOTO_FRAME_PART_PREFIX
import com.ztransfer.frame.hasFrameFor
import com.ztransfer.frame.isCurrentPhotoFrameTempName
import com.ztransfer.frame.isPhotoFrameOutputName
import com.ztransfer.frame.isPhotoPlacement
import com.ztransfer.frame.isSupportedPhotoFrameSourceExtension
import com.ztransfer.frame.migratedPhotoFrameWatermarkSizePercent
import com.ztransfer.frame.normalizePhotoFrameWatermarkOpacityPercent
import com.ztransfer.frame.normalizePhotoFrameWatermarkSizePercent
import com.ztransfer.frame.importPhotoFrameWatermarkImage as storePhotoFrameWatermarkImage
import com.ztransfer.frame.photoFrameWatermarkImageFile
import com.ztransfer.frame.validPhotoFrameWatermarkImageHash
import com.ztransfer.frame.decodePhotoFrameMetadataSettings
import com.ztransfer.frame.defaultPhotoFrameMetadataSettings
import com.ztransfer.frame.encodePhotoFrameMetadataSettings
import com.ztransfer.frame.normalizePhotoFrameMetadataSettings
import com.ztransfer.frame.resolvedPhotoFrameMetadataSettings
import com.ztransfer.filter.PhotoFilterPreset
import com.ztransfer.filter.BuiltInPhotoFilters
import com.ztransfer.filter.PhotoFilterRenderer
import com.ztransfer.filter.PhotoFilterSelection
import com.ztransfer.filter.DEFAULT_PHOTO_FILTER_INTENSITY_PERCENT
import com.ztransfer.filter.normalizePhotoFilterIntensity
import com.ztransfer.license.LicenseManager
import com.ztransfer.protocol.CameraConnectionType
import com.ztransfer.protocol.ExistingPartAction
import com.ztransfer.protocol.FailedPartAction
import com.ztransfer.protocol.NikonCamera
import com.ztransfer.protocol.PtpConstants
import com.ztransfer.protocol.ResumeUnavailableException
import com.ztransfer.protocol.TransferFailurePresentation
import com.ztransfer.protocol.classifyTransferFailurePresentation
import com.ztransfer.protocol.endToEndBytesPerSecond
import com.ztransfer.protocol.failedPartAction
import com.ztransfer.protocol.planExistingPart
import com.ztransfer.service.TransferService
import com.ztransfer.ui.theme.SkinPreset
import com.ztransfer.ui.theme.ThemeMode
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.time.LocalDate

private val transferTaskIds = AtomicLong(0L)
private const val PHOTO_FRAME_WATERMARK_SIZE_SCALE_VERSION = 2
private const val PHOTO_FRAME_WATERMARK_SIZE_SCALE_VERSION_KEY =
    "photo_frame_watermark_size_scale_version"
private const val PHOTO_FRAME_METADATA_SETTINGS_KEY = "photo_frame_metadata_settings_v1"
internal const val PHOTO_FRAME_EXPORT_PARALLELISM = 2

/** Android 继续持有原线程锁；纯索引和值模型由 shared 提供。 */
internal class ExistingFileNameIndex<T> {
    private val lock = Any()
    private val core = ExistingFileNameIndexCore<T>()

    fun add(displayName: String, size: Long, value: T) = synchronized(lock) {
        core.add(displayName, size, value)
    }

    fun containsDisplayName(displayName: String): Boolean = synchronized(lock) {
        core.containsDisplayName(displayName)
    }

    fun find(fileName: String, fileSize: Long): IndexedExistingFile<T>? = synchronized(lock) {
        core.find(fileName, fileSize)
    }

    fun entries(): List<IndexedExistingFile<T>> = synchronized(lock) {
        core.entries()
    }
}

data class TransferTask(
    val file: NikonCamera.FileInfo,
    /** 队列任务的进程内唯一标识；同一相机文件可以按不同装饰配置创建多个独立任务。 */
    override val taskId: Long = transferTaskIds.incrementAndGet(),
    /** 入队时锁定的边框样式；null 表示该任务不生成边框/水印派生图。 */
    val framePreset: PhotoFramePreset? = null,
    /** false 表示保留原照片画布，仅叠加画面内水印。 */
    val frameBorderRequested: Boolean = true,
    /** 入队时锁定当前边框的信息显隐与日期时间格式。 */
    val frameMetadataSettings: PhotoFrameMetadataSettings? = null,
    /** 与预设同时快照，避免排队期间修改设置改变已入队任务的输出。 */
    val frameWatermarkRequested: PhotoFrameWatermark = PhotoFrameWatermark(),
    /** 入队时锁定的滤镜；与边框互相独立，null 表示原片不做颜色处理。 */
    val photoFilterRequested: PhotoFilterSelection? = null,
    /** 非空时原图写入传输根目录下的该日期文件夹，效果图再写入其 ZTFrames 子目录。 */
    val destinationFolderName: String? = null,
    override val status: TransferStatus = TransferStatus.WAITING,
    val progress: Float = 0f,
    val speed: Long = 0,
    val downloaded: Long = 0,
    val error: String? = null,
    val skipped: Boolean = false,  // 目标目录已存在同名文件而跳过
    // 单文件下载速度（MB/s），完成后填入，显示在卡片上。
    val downloadMBps: Float = 0f,
    // 本次传输耗时（毫秒），完成后填入并显示在卡片上；跳过/未传的为 null。
    val elapsedMs: Long? = null,
    // 原片已成功落盘后的派生步骤；失败不改变 COMPLETED，原片始终保留。
    val isGeneratingFrame: Boolean = false,
    /** 用户看到“生成中”的单调时钟起点；仅在生成期间保留。 */
    val frameGenerationStartedAtElapsedMs: Long? = null,
    /** 单次派生从显示“生成中”到结束的用户可感知耗时。 */
    val frameGenerationElapsedMs: Long? = null,
) : TransferQueueItem

internal fun TransferTask.startFrameGeneration(nowElapsedMs: Long): TransferTask = copy(
    isGeneratingFrame = true,
    frameGenerationStartedAtElapsedMs = nowElapsedMs,
    frameGenerationElapsedMs = null,
)

internal fun TransferTask.finishFrameGeneration(nowElapsedMs: Long): TransferTask {
    if (!isGeneratingFrame) return this
    val elapsed = frameGenerationStartedAtElapsedMs?.let { startedAt ->
        (nowElapsedMs - startedAt).coerceAtLeast(0L)
    }
    return copy(
        isGeneratingFrame = false,
        frameGenerationStartedAtElapsedMs = null,
        frameGenerationElapsedMs = elapsed,
    )
}

/**
 * 当前导出目录中已落盘原片的 O(1) 查询索引，根层与各日期目录独立分桶。内容原地增量更新；[TransferState]
 * 通过 [TransferState.existingExportRevision] 发布一次轻量版本变化，避免每完成一张
 * 都复制整个索引。
 */
class ExportedOriginalIndex internal constructor() {
    private val filesByDestination =
        ConcurrentHashMap<String, ConcurrentHashMap<String, ConcurrentHashMap<Long, String>>>()

    internal fun add(
        fileName: String,
        size: Long,
        destinationFolderName: String? = null,
        uriString: String? = null,
    ): Boolean {
        val destinationKey = transferDestinationLookupKey(destinationFolderName)
        val fileKey = transferDirectoryLookupKey(fileName)
        val filesBySize = filesByDestination
            .computeIfAbsent(destinationKey) { ConcurrentHashMap() }
            .computeIfAbsent(fileKey) { ConcurrentHashMap() }
        if (uriString == null) return filesBySize.putIfAbsent(size, NO_LOCAL_URI) == null

        var changed = false
        filesBySize.compute(size) { _, existingUri ->
            if (existingUri != uriString) changed = true
            uriString
        }
        return changed
    }

    internal fun addAll(
        entries: Sequence<IndexedExistingFile<Uri>>,
        destinationFolderName: String? = null,
    ): Boolean {
        var changed = false
        entries.forEach { entry ->
            if (
                add(
                    fileName = entry.displayName,
                    size = entry.size,
                    destinationFolderName = destinationFolderName,
                    uriString = entry.value.toString(),
                )
            ) {
                changed = true
            }
        }
        return changed
    }

    internal fun contains(
        file: NikonCamera.FileInfo,
        destinationFolderName: String? = null,
    ): Boolean {
        val filesBySize = filesByDestination[transferDestinationLookupKey(destinationFolderName)]
            ?.get(transferDirectoryLookupKey(file.fileName))
            ?: return false
        return file.size == PtpConstants.SIZE_UNKNOWN ||
            filesBySize.keys.any { localSize ->
                matchesExistingFileSize(localSize, file.size)
            }
    }

    internal fun localUriString(
        file: NikonCamera.FileInfo,
        destinationFolderName: String? = null,
    ): String? {
        val filesBySize = filesByDestination[transferDestinationLookupKey(destinationFolderName)]
            ?.get(transferDirectoryLookupKey(file.fileName))
            ?: return null
        return if (file.size == PtpConstants.SIZE_UNKNOWN) {
            filesBySize.values.firstOrNull { it.isNotEmpty() }
        } else {
            filesBySize[file.size]?.takeIf { it.isNotEmpty() }
                ?: filesBySize.entries.firstOrNull {
                    it.key < 0L && it.value.isNotEmpty()
                }?.value
        }
    }

    private companion object {
        const val NO_LOCAL_URI = ""
    }
}

/**
 * 唯一活动下载的高频状态。它与低频 [TransferState.tasks] 分离：协议层约每 200ms 更新时
 * 只替换这个常量大小对象，不再复制整个任务列表，也不会令订阅设置/筛选的页面失效。
 */
internal fun TransferTask.withActiveProgress(
    active: ActiveTransferProgress?,
): TransferTask = if (active?.taskId == taskId && status == TransferStatus.TRANSFERING) {
    copy(
        progress = active.fraction,
        downloaded = active.downloaded,
        speed = active.bytesPerSecond,
    )
} else {
    this
}

/** 仅负责低频队列调度；任务历史继续留在 TransferState 供 UI 展示。 */
internal class PendingTransferQueue {
    private val lock = Any()
    private val queue = TransferTaskQueue<TransferTask>()

    fun addAll(newTasks: Collection<TransferTask>) = synchronized(lock) {
        queue.addAll(newTasks)
    }

    fun takeFirst(): TransferTask? = synchronized(lock) { queue.takeFirst() }

    /** 队列内任务直接移除；已经被调度器取走但尚在预检查的任务留下撤回标记。 */
    fun withdraw(taskIds: Collection<Long>) = synchronized(lock) {
        queue.withdraw(taskIds)
    }

    fun consumeWithdrawal(taskId: Long): Boolean = synchronized(lock) {
        queue.consumeWithdrawal(taskId)
    }

    fun clear() = synchronized(lock) {
        queue.clear()
    }
}

internal fun TransferTask.newAttempt(): TransferTask = copy(
    taskId = transferTaskIds.incrementAndGet(),
    status = TransferStatus.WAITING,
    progress = 0f,
    speed = 0L,
    downloaded = 0L,
    error = null,
    skipped = false,
    downloadMBps = 0f,
    elapsedMs = null,
    isGeneratingFrame = false,
    frameGenerationStartedAtElapsedMs = null,
    frameGenerationElapsedMs = null,
)

private fun NikonCamera.FileInfo.autoTransferIdentity(): String =
    automaticTransferFileIdentity(fileName, size, captureDate)

data class TransferState(
    val tasks: List<TransferTask> = emptyList(),
    /** 仅在任务增删或替换时递增；纯状态变化不会让照片页重建 handle -> 列表下标索引。 */
    val taskStructureRevision: Long = 0L,
    val isTransferring: Boolean = false,
    /** True after the user asks the running queue to stop at the next task boundary. */
    val pauseAfterCurrent: Boolean = false,
    val transferDirUri: String? = null,
    /** 根层及各日期目录内的完整文件索引，用于按当前保存方式标记已传照片。 */
    val existingExportIndex: ExportedOriginalIndex = ExportedOriginalIndex(),
    /** [existingExportIndex] 原地更新后的发布版本，只负责触发订阅者重新读取索引。 */
    val existingExportRevision: Long = 0L,
    val thumbnailColumns: Int = 3,
    // 连拍合集显示（默认关闭，保持旧版照片网格原样）：开启后列表把每段已识别的连拍
    // 收成一个可展开的虚拟卡位；原始文件集合、筛选和传输语义均不改变。
    val collapseBurstPhotos: Boolean = false,
    // 照片网格手势：默认保持轻触传输、长按预览；开启后只交换两个触发入口。
    val tapToPreview: Boolean = false,
    // 触感反馈开关：默认开启，用户关闭后持久化，下次启动保持。
    val hapticsEnabled: Boolean = true,
    // 屏幕常亮（默认开启）：应用在前台时不熄屏——熄屏后系统会冻结进程/让 Wi-Fi 打盹，
    // 相机连接容易断；代价是手机一直亮屏。
    val keepScreenOn: Boolean = true,
    // 每个说明入口分别记录是否真正点击过；仅清除应用数据或卸载后恢复未读引导。
    val mainSettingsHelpViewed: Boolean = false,
    val photoEffectsHelpViewed: Boolean = false,
    val apConnectionHelpViewed: Boolean = false,
    val staConnectionHelpViewed: Boolean = false,
    val localPhotoEffectsHelpViewed: Boolean = false,
    // 连接期间确认新增的照片和视频自动入队；默认关闭以保持旧版行为。
    val autoTransferNewMedia: Boolean = false,
    // 待传模式：空闲时入队只保留 WAITING，由传输页的开始按钮显式放行；默认关闭。
    val deferTransferStart: Boolean = false,
    // 原图按拍摄日写入 ZTyyyy-MM-dd 子目录，派生效果图位于该目录的 ZTFrames 中；默认开启。
    val organizeTransfersByDate: Boolean = false,
    // 主题模式：默认跟随系统深浅色，可在设置里固定深色/浅色。
    val themeMode: ThemeMode = ThemeMode.SYSTEM,
    // UI 皮肤预设（毛玻璃/经典等），全局配色与纹理风格。
    val skinPreset: SkinPreset = SkinPreset.FROSTED_GLASS,
    // 照片类型筛选（归一化扩展名，如 ".jpg"）：null = 全部（不过滤，新类型也放行）。
    // 持久化跨会话生效；设备上没有所选类型时列表自然为空，不做特殊处理。
    val filterExtensions: Set<String>? = null,
    // 只看机内"保护"(🔑)标记过的照片（机内选片工作流）。持久化。
    val filterProtectedOnly: Boolean = false,
    // 只看连拍照片（检测算法见 FileListScreen.computeBurstGroups）。持久化。
    val filterBurstOnly: Boolean = false,
    // 只看导出目录中尚未存在的照片。与缩略图已传对号共用同一份索引。持久化。
    val filterUntransferredOnly: Boolean = false,
    // 只看指定卡槽（1/2）。null = 两张卡全部显示。仅当前进程生效；下次启动恢复全部卡槽。
    val filterStorageSlot: Int? = null,
    // 相机拍摄日期范围（含首尾两天）。null = 不按日期筛选。持久化。
    val filterDateRange: PhotoDateRange? = null,
    // 预览大图的全局逆时针旋转方向（0..3 个 90°）。跨照片、跨会话持久化。
    val previewRotationQuarterTurns: Int = 0,
    // 照片预览直方图的可见状态。跨照片、跨预览会话与 App 重启持久化。
    val previewHistogramEnabled: Boolean = false,
    // 开启后：受支持的原图落盘成功，再派生一张保留原片细节的边框/水印效果图。
    val photoFrameEnabled: Boolean = false,
    // 总开关开启时，边框与水印可以独立组合；false 允许只在原照片上叠水印。
    val photoFrameBorderEnabled: Boolean = true,
    // 启用边框时采用的默认样式。派生图只另存新文件，永不覆盖原片。
    val photoFramePreset: PhotoFramePreset = PhotoFramePreset.MIST,
    val photoFrameMetadataSettings: Map<PhotoFramePreset, PhotoFrameMetadataSettings> = emptyMap(),
    // 自定义水印。免费版渲染时强制使用默认值；高级版可关闭和调整，并记住选择。
    val photoFrameWatermarkEnabled: Boolean = true,
    val photoFrameWatermarkContent: PhotoFrameWatermarkContent = PhotoFrameWatermarkContent.TEXT,
    val photoFrameWatermarkText: String = "ZTransfer",
    val photoFrameWatermarkImageHash: String? = null,
    val photoFrameWatermarkFont: PhotoFrameWatermarkFont = PhotoFrameWatermarkFont.CALLIGRAPHY,
    val photoFrameWatermarkSizePercent: Int = DEFAULT_PHOTO_FRAME_WATERMARK_SIZE_PERCENT,
    val photoFrameWatermarkPosition: PhotoFrameWatermarkPosition = PhotoFrameWatermarkPosition.AUTO,
    val photoFrameWatermarkColor: PhotoFrameWatermarkColor = PhotoFrameWatermarkColor.ADAPTIVE,
    val photoFrameWatermarkOpacityPercent: Int = DEFAULT_PHOTO_FRAME_WATERMARK_OPACITY_PERCENT,
    val photoFrameWatermarkEffect: PhotoFrameWatermarkEffect = PhotoFrameWatermarkEffect.AUTO,
    val photoFilters: List<PhotoFilterPreset> = emptyList(),
    val favoritePhotoFilters: List<FavoritePhotoFilter> = emptyList(),
    val favoriteFrameEffects: List<FavoriteFrameWatermarkEffect> = emptyList(),
    val photoFilterEnabled: Boolean = false,
    val selectedPhotoFilterId: String? = null,
    val photoFilterIntensityPercent: Int = DEFAULT_PHOTO_FILTER_INTENSITY_PERCENT,
    val transferPhotoFilterIntensities: Map<String, Int> = emptyMap(),
    // 应用内语言：BCP-47 标签（"en"/"zh-Hans"/"zh-Hant"）或 AppLocale.SYSTEM（跟随系统）。
    val appLanguage: String = AppLocale.SYSTEM
)

/**
 * Publishes a task list whose identity, order, or size changed and invalidates UI indexes derived
 * from that structure. Status/progress-only element replacements must continue to use [copy].
 */
internal fun TransferState.withTaskStructure(tasks: List<TransferTask>): TransferState = copy(
    tasks = tasks,
    taskStructureRevision = taskStructureRevision + 1L,
)

private val TransferState.transferExecutionState: TransferExecutionState
    get() = TransferExecutionState(isTransferring, pauseAfterCurrent)

private fun TransferState.withTransferExecutionState(
    execution: TransferExecutionState,
): TransferState = if (
    isTransferring == execution.isTransferring &&
    pauseAfterCurrent == execution.pauseAfterCurrent
) {
    this
} else {
    copy(
        isTransferring = execution.isTransferring,
        pauseAfterCurrent = execution.pauseAfterCurrent,
    )
}

/** 文件页所有筛选条件的原子快照，避免筛选项增加后依赖位置参数传递。 */
data class PhotoFilterCriteria(
    val extensions: Set<String>? = null,
    val protectedOnly: Boolean = false,
    val burstOnly: Boolean = false,
    val untransferredOnly: Boolean = false,
    val storageSlot: Int? = null,
    val dateRange: PhotoDateRange? = null,
) {
    companion object {
        val Default = PhotoFilterCriteria()
    }
}

internal fun normalizeThumbnailColumns(columns: Int): Int = columns.coerceIn(2, 4)

/** 迁移旧尺寸刻度；旧 50% 及以上保持视觉大小，低于 50% 的值归入新的最小档。 */
internal fun restoredPhotoFrameWatermarkSizePercent(
    persisted: Any?,
    content: PhotoFrameWatermarkContent,
    usesLegacyScale: Boolean = false,
): Int {
    if (persisted == null) return DEFAULT_PHOTO_FRAME_WATERMARK_SIZE_PERCENT
    val isLegacyNamedValue = persisted is String && persisted.toIntOrNull() == null
    val rawPercent = when (persisted) {
        is Number -> persisted.toInt()
        is String -> persisted.toIntOrNull() ?: when (persisted) {
            "SMALL" -> if (content == PhotoFrameWatermarkContent.IMAGE) 47 else 58
            "MEDIUM" -> if (content == PhotoFrameWatermarkContent.IMAGE) 69 else 75
            "LARGE" -> 100
            else -> 75
        }
        else -> DEFAULT_PHOTO_FRAME_WATERMARK_SIZE_PERCENT
    }
    return if (usesLegacyScale || isLegacyNamedValue) {
        migratedPhotoFrameWatermarkSizePercent(rawPercent)
    } else {
        normalizePhotoFrameWatermarkSizePercent(rawPercent)
    }
}

/** 兼容旧版 SUBTLE/STANDARD/STRONG 字符串；新版本直接持久化百分比。 */
internal fun restoredPhotoFrameWatermarkOpacityPercent(persisted: Any?): Int {
    val rawPercent = when (persisted) {
        is Number -> persisted.toInt()
        is String -> persisted.toIntOrNull() ?: when (persisted) {
            "SUBTLE" -> 40
            "STANDARD" -> 72
            "STRONG" -> 100
            else -> DEFAULT_PHOTO_FRAME_WATERMARK_OPACITY_PERCENT
        }
        else -> DEFAULT_PHOTO_FRAME_WATERMARK_OPACITY_PERCENT
    }
    return normalizePhotoFrameWatermarkOpacityPercent(rawPercent)
}

internal val TransferState.photoFrameWatermark: PhotoFrameWatermark
    get() = PhotoFrameWatermark(
        enabled = photoFrameWatermarkEnabled,
        content = photoFrameWatermarkContent,
        text = photoFrameWatermarkText,
        imageHash = photoFrameWatermarkImageHash,
        font = photoFrameWatermarkFont,
        sizePercent = photoFrameWatermarkSizePercent,
        position = photoFrameWatermarkPosition,
        color = photoFrameWatermarkColor,
        opacityPercent = photoFrameWatermarkOpacityPercent,
        effect = photoFrameWatermarkEffect,
    )

private const val FREE_PHOTO_FRAME_WATERMARK_SIZE_PERCENT =
    DEFAULT_PHOTO_FRAME_WATERMARK_SIZE_PERCENT
private const val FREE_PHOTO_FRAME_WATERMARK_OPACITY_PERCENT = 80

/** 免费版固定品牌水印；与高级版的默认偏好分开，避免产品水印调整覆盖用户设置。 */
internal fun freeEditionPhotoFrameWatermark(): PhotoFrameWatermark = PhotoFrameWatermark(
    sizePercent = FREE_PHOTO_FRAME_WATERMARK_SIZE_PERCENT,
    opacityPercent = FREE_PHOTO_FRAME_WATERMARK_OPACITY_PERCENT,
)

internal val TransferState.photoFilterSelection: PhotoFilterSelection?
    get() {
        if (!photoFilterEnabled) return null
        val preset = photoFilters.firstOrNull { it.id == selectedPhotoFilterId } ?: return null
        return PhotoFilterSelection(preset, photoFilterIntensityPercent)
    }

/** 免费版固定使用默认水印；高级版完整采用用户设置。预览和真正导出必须共用该入口。 */
internal fun effectivePhotoFrameWatermark(
    isPro: Boolean,
    preference: PhotoFrameWatermark,
    borderEnabled: Boolean = true,
): PhotoFrameWatermark {
    val permitted = if (isPro) preference else freeEditionPhotoFrameWatermark()
    val imageHash = validPhotoFrameWatermarkImageHash(permitted.imageHash)
    val content = if (
        permitted.content == PhotoFrameWatermarkContent.IMAGE && imageHash != null
    ) {
        PhotoFrameWatermarkContent.IMAGE
    } else {
        PhotoFrameWatermarkContent.TEXT
    }
    return permitted.copy(
        content = content,
        text = permitted.displayText,
        imageHash = imageHash,
        sizePercent = normalizePhotoFrameWatermarkSizePercent(permitted.sizePercent),
        opacityPercent = normalizePhotoFrameWatermarkOpacityPercent(permitted.opacityPercent),
        position = if ((!borderEnabled || content == PhotoFrameWatermarkContent.IMAGE) &&
            !permitted.position.isPhotoPlacement()
        ) {
            PhotoFrameWatermarkPosition.PHOTO_BOTTOM_CENTER
        } else {
            permitted.position
        },
    )
}

/** Normalizes persisted watermark values without replacing a temporarily unavailable position. */
internal fun normalizedPhotoFrameWatermarkPreference(
    preference: PhotoFrameWatermark,
    borderEnabled: Boolean,
): PhotoFrameWatermark = effectivePhotoFrameWatermark(
    isPro = true,
    preference = preference,
    borderEnabled = borderEnabled,
).copy(position = preference.position)

/** 只允许 JPG/JPEG/PNG 派生效果图；视频、RAW 和未知类型始终保持原样传输。 */
internal fun shouldGeneratePhotoFrame(enabled: Boolean, extension: String): Boolean =
    enabled && isSupportedPhotoFrameSourceExtension(extension)

/** PTP 拍摄时间通常为 yyyyMMdd'T'HHmmss；异常或缺失时固定回退到入队当天。 */
internal fun transferDateFolderName(
    captureDate: String?,
    fallbackDate: LocalDate = LocalDate.now(),
): String = transferDateFolderName(
    captureDate = captureDate,
    fallbackDayKey = fallbackDate.year * 10_000 + fallbackDate.monthValue * 100 + fallbackDate.dayOfMonth,
)

internal fun transferDestinationFolderName(
    captureDate: String?,
    organizeTransfersByDate: Boolean,
    fallbackDate: LocalDate = LocalDate.now(),
): String? {
    return transferDestinationFolderName(
        captureDate = captureDate,
        organizeTransfersByDate = organizeTransfersByDate,
        fallbackDayKey = fallbackDate.year * 10_000 + fallbackDate.monthValue * 100 + fallbackDate.dayOfMonth,
    )
}

/** 相机文件是否已在当前保存目录中落盘；列表对号、筛选和任务模式必须共用该判定。 */
internal fun isTransferredOriginal(
    file: NikonCamera.FileInfo,
    existingExportIndex: ExportedOriginalIndex,
    organizeTransfersByDate: Boolean,
): Boolean = existingExportIndex.contains(
    file = file,
    destinationFolderName = transferDestinationFolderName(
        captureDate = file.captureDate,
        organizeTransfersByDate = organizeTransfersByDate,
    ),
)

/** Returns the already-indexed local original for preview, using the exact same destination rule. */
internal fun transferredOriginalUri(
    file: NikonCamera.FileInfo,
    existingExportIndex: ExportedOriginalIndex,
    organizeTransfersByDate: Boolean,
): Uri? = existingExportIndex.localUriString(
    file = file,
    destinationFolderName = transferDestinationFolderName(
        captureDate = file.captureDate,
        organizeTransfersByDate = organizeTransfersByDate,
    ),
)?.let(Uri::parse)

/** 已入队任务使用入队时锁定的目标目录，不受之后的“按天保存”开关变化影响。 */
internal fun isTransferredOriginal(
    file: NikonCamera.FileInfo,
    existingExportIndex: ExportedOriginalIndex,
    destinationFolderName: String?,
): Boolean = existingExportIndex.contains(file, destinationFolderName)

internal fun createQueueTasks(
    files: List<NikonCamera.FileInfo>,
    photoFrameEnabled: Boolean,
    photoFrameBorderEnabled: Boolean = true,
    photoFramePreset: PhotoFramePreset,
    photoFrameWatermark: PhotoFrameWatermark,
    photoFrameMetadataSettings: PhotoFrameMetadataSettings =
        defaultPhotoFrameMetadataSettings(photoFramePreset),
    photoFilter: PhotoFilterSelection? = null,
    organizeTransfersByDate: Boolean = false,
    queuedDate: LocalDate = LocalDate.now(),
): List<TransferTask> = files.asSequence()
    // 同一次批量点击按相机文件去重；不同点击始终创建独立任务。
    .distinctBy { it.handle }
    .map { file ->
        TransferTask(
            file = file,
            framePreset = photoFramePreset.takeIf {
                shouldGeneratePhotoFrame(photoFrameEnabled, file.extension)
            },
            frameBorderRequested = photoFrameBorderEnabled,
            frameMetadataSettings = photoFrameMetadataSettings,
            frameWatermarkRequested = photoFrameWatermark,
            photoFilterRequested = photoFilter.takeIf {
                isSupportedPhotoFrameSourceExtension(file.extension)
            },
            destinationFolderName = transferDestinationFolderName(
                captureDate = file.captureDate,
                organizeTransfersByDate = organizeTransfersByDate,
                fallbackDate = queuedDate,
            ),
        )
    }
    .toList()

internal const val REMOTE_ENTRY_INTRO_MAX_PLAYS = 6

internal fun isRemoteEntryIntroEligible(playCount: Int): Boolean =
    playCount.coerceAtLeast(0) < REMOTE_ENTRY_INTRO_MAX_PLAYS

class TransferViewModel(application: Application) : AndroidViewModel(application) {
    private val _state = MutableStateFlow(TransferState())
    val state: StateFlow<TransferState> = _state.asStateFlow()
    private val _activeTransferProgress = MutableStateFlow<ActiveTransferProgress?>(null)
    val activeTransferProgress: StateFlow<ActiveTransferProgress?> =
        _activeTransferProgress.asStateFlow()
    @Volatile
    private var lastValidTransferSpeed = 0L
    private val pendingTransferQueue = PendingTransferQueue()
    private val directoryIndexLock = Any()
    private val directoryIndexes = HashMap<String, ExistingDirectoryIndex>()
    private val directoryIndexScans = HashMap<String, Deferred<ExistingDirectoryIndex>>()
    private val datedTransferDirectories = ConcurrentHashMap<String, Uri>()

    private var transferJob: Job? = null
    private var photoFilterPrewarmJob: Job? = null
    private var photoFilterPrewarmSelection: PhotoFilterSelection? = null
    @Volatile
    private var preferHighThroughputTransfers: Boolean = false
    private val prefs = application.getSharedPreferences("ztransfer", Context.MODE_PRIVATE)
    private val contentResolver = application.contentResolver
    /**
     * 原图品质效果导出使用两个低优先级工作线程：既能并行生成，又把完整位图的并发
     * 内存峰值限制在两张，不随 CPU 核数盲目扩大。相机传输仍使用原来的高优先级通道。
     */
    private val photoFrameWorkerIds = AtomicInteger(0)
    private val photoFrameDispatcher = Executors.newFixedThreadPool(
        PHOTO_FRAME_EXPORT_PARALLELISM,
    ) { task ->
        Thread(
            {
                android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_BACKGROUND)
                task.run()
            },
            "photo-frame-export-${photoFrameWorkerIds.incrementAndGet()}",
        )
    }.asCoroutineDispatcher()
    private val activePhotoFrameExports = AtomicInteger(0)
    // 第一张派生图才创建/扫描专用子目录；同一根目录后续任务复用，避免逐张遍历文件夹。
    private val photoFrameDestinations =
        ConcurrentHashMap<String, PhotoFrameDestination>()

    private fun getOrPreparePhotoFrameDestination(
        treeUri: Uri,
        parentDirectoryUri: Uri,
    ): PhotoFrameDestination {
        val key = "${treeUri}|${parentDirectoryUri}"
        photoFrameDestinations[key]?.let { return it }
        return synchronized(photoFrameDestinations) {
            photoFrameDestinations[key] ?: PhotoFrameExporter.prepareDestination(
                resolver = contentResolver,
                treeUri = treeUri,
                parentDirectoryUri = parentDirectoryUri,
            ).also { photoFrameDestinations[key] = it }
        }
    }

    /** 用户可见文案（错误信息等）统一走字符串资源；经 AppLocale.wrap 与应用内语言一致。 */
    private fun str(resId: Int, vararg args: Any?): String =
        AppLocale.wrap(getApplication()).getString(resId, *args)

    /**
     * 把底层异常翻译成用户可读的三语文案：网络类异常（断联/超时/连接重置——卡片上
     * 曾裸露 "software caused connection abort" 这类系统原文）统一显示"相机连接中断"；
     * 目录失效单独指认；其余保留自带信息（多为我们自己抛出的已本地化业务文案）。
     */
    private fun friendlyError(e: Throwable?): String {
        val message = e?.message
        return when (
            classifyTransferFailurePresentation(
                message = message,
                isConnectionException = e is java.net.SocketException ||
                    e is java.net.SocketTimeoutException ||
                    e is java.io.EOFException,
                isDirectoryException = e is java.io.FileNotFoundException,
            )
        ) {
            TransferFailurePresentation.GENERIC -> str(R.string.transfer_failed)
            TransferFailurePresentation.CONNECTION_LOST ->
                str(R.string.error_camera_connection_lost)
            TransferFailurePresentation.DIRECTORY_INVALID -> str(R.string.error_dir_invalid)
            TransferFailurePresentation.PASSTHROUGH_MESSAGE -> message.orEmpty()
        }
    }

    // 鸿蒙适配：部分华为/荣耀设备的 DocumentsProvider renameDocument 损坏（无论目标名
    // 是否空闲都失败），下载完好的临时文件改不了正式名 → 每张都"保存失败"。
    // 首次确认损坏后置位，本会话后续文件跳过改名直接走"复制为正式文件"回退路径，
    // 不再每个文件白试上百次改名。安卓正常设备永远不会置位，行为零变化。
    private var renameBroken = false

    private companion object {
        const val TAG = "ZTransfer"
        const val KEY_REMOTE_ENTRY_INTRO_PLAY_COUNT = "remote_entry_intro_play_count"
        const val KEY_MAIN_SETTINGS_HELP_VIEWED = "main_settings_help_viewed"
        const val KEY_PHOTO_EFFECTS_HELP_VIEWED = "photo_effects_help_viewed"
        const val KEY_AP_CONNECTION_HELP_VIEWED = "ap_connection_help_viewed"
        const val KEY_STA_CONNECTION_HELP_VIEWED = "sta_connection_help_viewed"
        const val KEY_LOCAL_PHOTO_EFFECTS_HELP_VIEWED = "local_photo_effects_help_viewed"
    }

    /** 半成品文件信息：用于断点续传。[token] = 文件内容身份（大小+拍摄时间），
     *  防止同名不同文件（DSC 编号跨文件夹回卷）续传时张冠李戴、把两份数据拼接成损坏文件。 */
    private data class PartInfo(val uri: Uri, val size: Long, val token: String)

    private data class LocalOriginal(
        val displayName: String,
        val size: Long,
        val uri: Uri,
    )

    /** 精确显示名与归一化原文件名双索引；副本匹配不再逐项遍历整个目录。 */
    private class ExistingDirectoryIndex {
        private val lock = Any()
        private val files = ExistingFileNameIndex<Uri>()
        private val partsByOriginalName = HashMap<String, PartInfo>()

        fun addFile(displayName: String, size: Long, uri: Uri) = files.add(displayName, size, uri)

        fun containsDisplayName(displayName: String): Boolean = files.containsDisplayName(displayName)

        fun findOriginal(file: NikonCamera.FileInfo): LocalOriginal? = files
            .find(file.fileName, file.size)
            ?.let { LocalOriginal(it.displayName, it.size, it.value) }

        fun exportedOriginalEntries(): Sequence<IndexedExistingFile<Uri>> = files.entries()
                .asSequence()
                .filterNot {
                    isPhotoFrameOutputName(it.displayName) ||
                        it.displayName.equals(PHOTO_FRAME_OUTPUT_DIRECTORY, ignoreCase = true)
                }
                .map {
                    IndexedExistingFile(
                        displayName = exportedOriginalBaseName(it.displayName),
                        size = it.size,
                        value = it.value,
                    )
                }

        fun addPart(originalName: String, part: PartInfo) = synchronized(lock) {
            partsByOriginalName[originalName] = part
        }

        fun partFor(originalName: String): PartInfo? = synchronized(lock) {
            partsByOriginalName[originalName]
        }

        fun removePart(originalName: String) = synchronized(lock) {
            partsByOriginalName.remove(originalName)
        }
    }

    /**
     * 由导航宿主同步当前页面是否应优先保证无线传输吞吐。该值不持久化，也不修改正在
     * 传输的文件；每张文件在调用协议层前只读取一次。导航在主线程写、协议在 IO 线程读，
     * 因此用 volatile 保证下一张文件能立即看到最新页面策略。
     */
    fun setPreferHighThroughputTransfers(enabled: Boolean) {
        preferHighThroughputTransfers = enabled
    }

    /** 监看入口自解释动画最多跨启动展示六次，之后不再打扰已经熟悉入口的用户。 */
    internal fun shouldShowRemoteEntryIntro(): Boolean = isRemoteEntryIntroEligible(
        prefs.getInt(KEY_REMOTE_ENTRY_INTRO_PLAY_COUNT, 0),
    )

    /** 仅在动画真正开始时调用；apply 先同步更新内存值，再异步落盘，不阻塞主线程。 */
    internal fun recordRemoteEntryIntroPlayed() {
        val playCount = prefs.getInt(KEY_REMOTE_ENTRY_INTRO_PLAY_COUNT, 0).coerceAtLeast(0)
        if (!isRemoteEntryIntroEligible(playCount)) return
        prefs.edit()
            .putInt(KEY_REMOTE_ENTRY_INTRO_PLAY_COUNT, playCount + 1)
            .apply()
    }

    private sealed interface FrameExportOutcome {
        data class Saved(val displayName: String) : FrameExportOutcome
        data class Failed(val error: Throwable) : FrameExportOutcome
        object AlreadyExists : FrameExportOutcome
    }

    /** 文件内容身份令牌：大小+拍摄时间，仅留字母数字与点（内嵌半成品名，不含下划线分隔符）。 */
    private fun identityToken(file: NikonCamera.FileInfo): String =
        transferPartIdentityToken(file.size, file.captureDate)

    /** 半成品文件名 = 前缀 + 身份令牌 + "_" + 原文件名（原名可含下划线，解析按【首个】下划线切分）。 */
    private fun partFileName(file: NikonCamera.FileInfo): String =
        transferPartFileName(file.fileName, file.size, file.captureDate)

    init {
        val dir = prefs.getString("transfer_dir", null)
        val restoredPhotoFilters = BuiltInPhotoFilters.all
        val validPhotoFilterCatalogKeys = restoredPhotoFilters
            .mapNotNull { BuiltInPhotoFilters.catalogKey(it.id) }
            .toSet()
        val decodedFavoritePhotoFilters = decodeFavoritePhotoFilters(
            prefs.getString(FAVORITE_PHOTO_FILTERS_PREFERENCE_KEY, null),
            validPhotoFilterCatalogKeys,
        )
        val restoredFavoriteFrameEffects = decodeFavoriteFrameEffects(
            prefs.getString(FAVORITE_FRAME_EFFECTS_PREFERENCE_KEY, null),
        )
        val storedPhotoFilterId = prefs.getString("photo_filter_selected_id", null)
        val restoredPhotoFilterId = storedPhotoFilterId
            ?.takeIf { id -> restoredPhotoFilters.any { it.id == id } }
            ?: restoredPhotoFilters.firstOrNull()?.id
        val restoredPhotoFilterIntensities = buildMap {
            if (prefs.contains("photo_filter_intensity")) {
                restoredPhotoFilterId
                    ?.let(BuiltInPhotoFilters::catalogKey)
                    ?.let { catalogKey ->
                        put(
                            catalogKey,
                            normalizePhotoFilterIntensity(
                                prefs.getInt(
                                    "photo_filter_intensity",
                                    DEFAULT_PHOTO_FILTER_INTENSITY_PERCENT,
                                ),
                            ),
                        )
                    }
            }
            putAll(
                decodePhotoFilterIntensities(
                    prefs.getString(PHOTO_FILTER_INTENSITIES_PREFERENCE_KEY, null),
                    validPhotoFilterCatalogKeys,
                )
            )
        }
        val encodedPhotoFilterIntensities =
            encodePhotoFilterIntensities(restoredPhotoFilterIntensities)
        if (prefs.getString(PHOTO_FILTER_INTENSITIES_PREFERENCE_KEY, null) !=
            encodedPhotoFilterIntensities || prefs.contains("photo_filter_intensity")
        ) {
            prefs.edit()
                .putString(
                    PHOTO_FILTER_INTENSITIES_PREFERENCE_KEY,
                    encodedPhotoFilterIntensities,
                )
                .remove("photo_filter_intensity")
                .apply()
        }
        val encodedFavoritePhotoFilters = encodeFavoritePhotoFilters(decodedFavoritePhotoFilters)
        if (prefs.getString(FAVORITE_PHOTO_FILTERS_PREFERENCE_KEY, null) !=
            encodedFavoritePhotoFilters
        ) {
            prefs.edit()
                .putString(
                    FAVORITE_PHOTO_FILTERS_PREFERENCE_KEY,
                    encodedFavoritePhotoFilters,
                )
                .apply()
        }
        val storedSkinName = prefs.getString("skin_preset", null)
        val restoredSkinPreset = if (storedSkinName == null) {
            SkinPreset.FROSTED_GLASS
        } else {
            SkinPreset.entries.firstOrNull { it.name == storedSkinName } ?: SkinPreset.TITANIUM
        }
        // 已下线的旧材质或异常值统一迁移到钛合金，并立即写回新枚举名。
        if (storedSkinName != null && storedSkinName != restoredSkinPreset.name) {
            prefs.edit().putString("skin_preset", restoredSkinPreset.name).apply()
        }
        val restoredWatermarkImageHash = validPhotoFrameWatermarkImageHash(
            prefs.getString("photo_frame_watermark_image_hash", null)
        )?.takeIf { hash -> photoFrameWatermarkImageFile(application, hash).isFile }
        val restoredWatermarkContent = runCatching {
            PhotoFrameWatermarkContent.valueOf(
                prefs.getString(
                    "photo_frame_watermark_content",
                    PhotoFrameWatermarkContent.TEXT.name,
                ) ?: PhotoFrameWatermarkContent.TEXT.name,
            )
        }.getOrDefault(PhotoFrameWatermarkContent.TEXT).let { content ->
            if (content == PhotoFrameWatermarkContent.IMAGE && restoredWatermarkImageHash == null) {
                PhotoFrameWatermarkContent.TEXT
            } else {
                content
            }
        }
        val storedPreferences = prefs.all
        // 卡槽筛选只属于当前相机会话。清掉旧版本曾持久化的值，避免升级后继续恢复单卡状态。
        if ("filter_storage_slot" in storedPreferences) {
            prefs.edit().remove("filter_storage_slot").apply()
        }
        val storedWatermarkSize = storedPreferences["photo_frame_watermark_size"]
        val usesLegacyWatermarkSizeScale = prefs.getInt(
            PHOTO_FRAME_WATERMARK_SIZE_SCALE_VERSION_KEY,
            1,
        ) < PHOTO_FRAME_WATERMARK_SIZE_SCALE_VERSION
        val restoredWatermarkSizePercent = restoredPhotoFrameWatermarkSizePercent(
            storedWatermarkSize,
            restoredWatermarkContent,
            usesLegacyWatermarkSizeScale,
        )
        val storedWatermarkOpacity = storedPreferences["photo_frame_watermark_opacity"]
        val restoredWatermarkOpacityPercent =
            restoredPhotoFrameWatermarkOpacityPercent(storedWatermarkOpacity)
        val sizeNeedsMigration = usesLegacyWatermarkSizeScale ||
            (storedWatermarkSize != null &&
                (storedWatermarkSize !is Number ||
                    storedWatermarkSize.toInt() != restoredWatermarkSizePercent))
        val opacityNeedsMigration = storedWatermarkOpacity != null &&
            (storedWatermarkOpacity !is Number ||
                storedWatermarkOpacity.toInt() != restoredWatermarkOpacityPercent)
        if (sizeNeedsMigration || opacityNeedsMigration) {
            prefs.edit()
                .putInt("photo_frame_watermark_size", restoredWatermarkSizePercent)
                .putInt(
                    PHOTO_FRAME_WATERMARK_SIZE_SCALE_VERSION_KEY,
                    PHOTO_FRAME_WATERMARK_SIZE_SCALE_VERSION,
                )
                .putInt("photo_frame_watermark_opacity", restoredWatermarkOpacityPercent)
                .apply()
        }
        _state.update {
            it.copy(
                transferDirUri = dir,
                thumbnailColumns = normalizeThumbnailColumns(
                    prefs.getInt("thumbnail_columns", 3)
                ),
                collapseBurstPhotos = prefs.getBoolean("collapse_burst_photos", true),
                tapToPreview = prefs.getBoolean("tap_to_preview", false),
                hapticsEnabled = prefs.getBoolean("haptics_enabled", true),
                keepScreenOn = prefs.getBoolean("keep_screen_on", true),
                mainSettingsHelpViewed = prefs.getBoolean(
                    KEY_MAIN_SETTINGS_HELP_VIEWED,
                    false,
                ),
                photoEffectsHelpViewed = prefs.getBoolean(
                    KEY_PHOTO_EFFECTS_HELP_VIEWED,
                    false,
                ),
                apConnectionHelpViewed = prefs.getBoolean(
                    KEY_AP_CONNECTION_HELP_VIEWED,
                    false,
                ),
                staConnectionHelpViewed = prefs.getBoolean(
                    KEY_STA_CONNECTION_HELP_VIEWED,
                    false,
                ),
                localPhotoEffectsHelpViewed = prefs.getBoolean(
                    KEY_LOCAL_PHOTO_EFFECTS_HELP_VIEWED,
                    false,
                ),
                autoTransferNewMedia = prefs.getBoolean("auto_transfer_new_media", false),
                deferTransferStart = prefs.getBoolean("defer_transfer_start", false),
                organizeTransfersByDate = prefs.getBoolean("organize_transfers_by_date", false),
                themeMode = prefs.getString("theme_mode", null)
                    ?.let { m -> ThemeMode.entries.firstOrNull { e -> e.name == m } }
                    ?: ThemeMode.SYSTEM,
                skinPreset = restoredSkinPreset,
                // getStringSet 返回的实例不可直接持有（SharedPreferences 约定），拷贝一份。
                filterExtensions = prefs.getStringSet("filter_exts", null)?.toSet(),
                filterProtectedOnly = prefs.getBoolean("filter_protected", false),
                filterBurstOnly = prefs.getBoolean("filter_burst", false),
                filterUntransferredOnly = prefs.getBoolean("filter_untransferred", false),
                filterDateRange = PhotoDateRange.restore(
                    prefs.getString("filter_date_start", null),
                    prefs.getString("filter_date_end", null),
                ),
                previewRotationQuarterTurns = Math.floorMod(
                    prefs.getInt("preview_rotation_quarter_turns", 0), 4
                ),
                previewHistogramEnabled = prefs.getBoolean(
                    "preview_histogram_enabled",
                    false,
                ),
                photoFrameEnabled = prefs.getBoolean("photo_frame_enabled", false),
                photoFrameBorderEnabled = prefs.getBoolean("photo_frame_border_enabled", true),
                photoFramePreset = runCatching {
                    PhotoFramePreset.valueOf(
                        prefs.getString("photo_frame_preset", PhotoFramePreset.MIST.name)
                            ?: PhotoFramePreset.MIST.name
                    )
                }.getOrDefault(PhotoFramePreset.MIST),
                photoFrameMetadataSettings = decodePhotoFrameMetadataSettings(
                    prefs.getString(PHOTO_FRAME_METADATA_SETTINGS_KEY, null),
                ),
                photoFrameWatermarkEnabled =
                    prefs.getBoolean("photo_frame_branding_enabled", true),
                photoFrameWatermarkContent = restoredWatermarkContent,
                photoFrameWatermarkText =
                    prefs.getString("photo_frame_watermark_text", "ZTransfer") ?: "ZTransfer",
                photoFrameWatermarkImageHash = restoredWatermarkImageHash,
                photoFrameWatermarkFont = runCatching {
                    PhotoFrameWatermarkFont.valueOf(
                        prefs.getString(
                            "photo_frame_watermark_font",
                            PhotoFrameWatermarkFont.CALLIGRAPHY.name,
                        ) ?: PhotoFrameWatermarkFont.CALLIGRAPHY.name,
                    )
                }.getOrDefault(PhotoFrameWatermarkFont.CALLIGRAPHY),
                photoFrameWatermarkSizePercent = restoredWatermarkSizePercent,
                photoFrameWatermarkPosition = runCatching {
                    PhotoFrameWatermarkPosition.valueOf(
                        prefs.getString(
                            "photo_frame_watermark_position",
                            PhotoFrameWatermarkPosition.AUTO.name,
                        ) ?: PhotoFrameWatermarkPosition.AUTO.name,
                    )
                }.getOrDefault(PhotoFrameWatermarkPosition.AUTO),
                photoFrameWatermarkColor = runCatching {
                    PhotoFrameWatermarkColor.valueOf(
                        prefs.getString(
                            "photo_frame_watermark_color",
                            PhotoFrameWatermarkColor.ADAPTIVE.name,
                        ) ?: PhotoFrameWatermarkColor.ADAPTIVE.name,
                    )
                }.getOrDefault(PhotoFrameWatermarkColor.ADAPTIVE),
                photoFrameWatermarkOpacityPercent = restoredWatermarkOpacityPercent,
                photoFrameWatermarkEffect = runCatching {
                    PhotoFrameWatermarkEffect.valueOf(
                        prefs.getString(
                            "photo_frame_watermark_effect",
                            PhotoFrameWatermarkEffect.AUTO.name,
                        ) ?: PhotoFrameWatermarkEffect.AUTO.name,
                    )
                }.getOrDefault(PhotoFrameWatermarkEffect.AUTO),
                photoFilters = restoredPhotoFilters,
                favoritePhotoFilters = decodedFavoritePhotoFilters,
                favoriteFrameEffects = restoredFavoriteFrameEffects,
                photoFilterEnabled = storedPhotoFilterId == restoredPhotoFilterId &&
                    prefs.getBoolean("photo_filter_enabled", false),
                selectedPhotoFilterId = restoredPhotoFilterId,
                photoFilterIntensityPercent = restoredPhotoFilterId
                    ?.let(BuiltInPhotoFilters::catalogKey)
                    ?.let(restoredPhotoFilterIntensities::get)
                    ?: DEFAULT_PHOTO_FILTER_INTENSITY_PERCENT,
                transferPhotoFilterIntensities = restoredPhotoFilterIntensities,
                appLanguage = prefs.getString(AppLocale.PREF_KEY, AppLocale.SYSTEM) ?: AppLocale.SYSTEM
            )
        }
        // 开 App 时清扫上次崩溃/被杀留下的半成品（.nkpart_ 临时文件）。
        if (dir != null) {
            val uri = Uri.parse(dir)
            // 构造 ViewModel 时同步登记清扫任务，再交给 IO 执行；用户极快点击传输时
            // 也只会等待这一份扫描，不会抢先建立一个“不清扫半成品”的竞争快照。
            primeDirectoryIndexScan(uri, deleteParts = true)
            viewModelScope.launch(Dispatchers.IO) {
                refreshExistingExportFiles(uri, deleteParts = true)
            }
        }
    }

    fun setThumbnailColumns(columns: Int) {
        val c = normalizeThumbnailColumns(columns)
        prefs.edit().putInt("thumbnail_columns", c).apply()
        _state.update { it.copy(thumbnailColumns = c) }
    }

    fun setCollapseBurstPhotos(enabled: Boolean) {
        prefs.edit().putBoolean("collapse_burst_photos", enabled).apply()
        _state.update { it.copy(collapseBurstPhotos = enabled) }
    }

    fun setTapToPreview(enabled: Boolean) {
        prefs.edit().putBoolean("tap_to_preview", enabled).apply()
        _state.update { it.copy(tapToPreview = enabled) }
    }

    fun setThemeMode(mode: ThemeMode) {
        prefs.edit().putString("theme_mode", mode.name).apply()
        _state.update { it.copy(themeMode = mode) }
    }

    fun setSkinPreset(skin: SkinPreset) {
        prefs.edit().putString("skin_preset", skin.name).apply()
        _state.update { it.copy(skinPreset = skin) }
    }

    fun setHapticsEnabled(enabled: Boolean) {
        prefs.edit().putBoolean("haptics_enabled", enabled).apply()
        _state.update { it.copy(hapticsEnabled = enabled) }
    }

    fun setKeepScreenOn(enabled: Boolean) {
        prefs.edit().putBoolean("keep_screen_on", enabled).apply()
        _state.update { it.copy(keepScreenOn = enabled) }
    }

    fun markMainSettingsHelpViewed() {
        if (_state.value.mainSettingsHelpViewed) return
        prefs.edit().putBoolean(KEY_MAIN_SETTINGS_HELP_VIEWED, true).apply()
        _state.update { it.copy(mainSettingsHelpViewed = true) }
    }

    fun markPhotoEffectsHelpViewed() {
        if (_state.value.photoEffectsHelpViewed) return
        prefs.edit().putBoolean(KEY_PHOTO_EFFECTS_HELP_VIEWED, true).apply()
        _state.update { it.copy(photoEffectsHelpViewed = true) }
    }

    fun markApConnectionHelpViewed() {
        if (_state.value.apConnectionHelpViewed) return
        prefs.edit().putBoolean(KEY_AP_CONNECTION_HELP_VIEWED, true).apply()
        _state.update { it.copy(apConnectionHelpViewed = true) }
    }

    fun markStaConnectionHelpViewed() {
        if (_state.value.staConnectionHelpViewed) return
        prefs.edit().putBoolean(KEY_STA_CONNECTION_HELP_VIEWED, true).apply()
        _state.update { it.copy(staConnectionHelpViewed = true) }
    }

    /** STA 连接失败时重新提示连接指引。 */
    fun resetStaConnectionHelpViewed() {
        if (!_state.value.staConnectionHelpViewed) return
        prefs.edit().putBoolean(KEY_STA_CONNECTION_HELP_VIEWED, false).apply()
        _state.update { it.copy(staConnectionHelpViewed = false) }
    }

    fun markLocalPhotoEffectsHelpViewed() {
        if (_state.value.localPhotoEffectsHelpViewed) return
        prefs.edit().putBoolean(KEY_LOCAL_PHOTO_EFFECTS_HELP_VIEWED, true).apply()
        _state.update { it.copy(localPhotoEffectsHelpViewed = true) }
    }

    fun setAutoTransferNewMedia(enabled: Boolean) {
        prefs.edit().putBoolean("auto_transfer_new_media", enabled).apply()
        _state.update { it.copy(autoTransferNewMedia = enabled) }
    }

    fun setDeferTransferStart(enabled: Boolean) {
        prefs.edit().putBoolean("defer_transfer_start", enabled).apply()
        _state.update { it.copy(deferTransferStart = enabled) }
    }

    fun setOrganizeTransfersByDate(enabled: Boolean) {
        prefs.edit().putBoolean("organize_transfers_by_date", enabled).apply()
        _state.update { it.copy(organizeTransfersByDate = enabled) }
    }

    /** 保存预览大图的全局旋转方向；任何照片和下次启动都复用。 */
    fun setPreviewRotationQuarterTurns(turns: Int) {
        val normalized = Math.floorMod(turns, 4)
        prefs.edit().putInt("preview_rotation_quarter_turns", normalized).apply()
        _state.update { it.copy(previewRotationQuarterTurns = normalized) }
    }

    /** 保存照片预览直方图开关；退出预览或重启 App 后继续沿用。 */
    fun setPreviewHistogramEnabled(enabled: Boolean) {
        prefs.edit().putBoolean("preview_histogram_enabled", enabled).apply()
        _state.update { it.copy(previewHistogramEnabled = enabled) }
    }

    fun setPhotoFrameEnabled(enabled: Boolean) {
        val snapshot = _state.value
        val effectiveWatermark = effectivePhotoFrameWatermark(
            isPro = LicenseManager.isPro.value,
            preference = snapshot.photoFrameWatermark,
            borderEnabled = snapshot.photoFrameBorderEnabled,
        )
        val restoreBorder = enabled &&
            !snapshot.photoFrameBorderEnabled && !effectiveWatermark.enabled
        val borderEnabled = if (restoreBorder) true else snapshot.photoFrameBorderEnabled
        prefs.edit()
            .putBoolean("photo_frame_enabled", enabled)
            .putBoolean("photo_frame_border_enabled", borderEnabled)
            .apply()
        _state.update { state ->
            state.copy(
                photoFrameEnabled = enabled,
                photoFrameBorderEnabled = borderEnabled,
            )
        }
    }

    /**
     * 二级页退出时一次提交边框与水印，避免逐字写偏好或让主设置短暂显示半套新配置。
     * 免费版即使绕过 UI 传入水印也会被忽略，只允许更新边框样式。
     */
    fun setPhotoFrameConfiguration(
        borderEnabled: Boolean,
        preset: PhotoFramePreset,
        watermark: PhotoFrameWatermark?,
    ) {
        val normalized = watermark
            ?.takeIf { LicenseManager.isPro.value }
            ?.let { normalizedPhotoFrameWatermarkPreference(it, borderEnabled) }
        val effectiveWatermark = normalized ?: effectivePhotoFrameWatermark(
            isPro = LicenseManager.isPro.value,
            preference = _state.value.photoFrameWatermark,
            borderEnabled = borderEnabled,
        )
        val decorationEnabled = borderEnabled || effectiveWatermark.enabled
        prefs.edit().apply {
            putBoolean("photo_frame_enabled", decorationEnabled)
            putBoolean("photo_frame_border_enabled", borderEnabled)
            putString("photo_frame_preset", preset.name)
            normalized?.let {
                // 沿用旧 key，升级用户原有的水印开关偏好无需迁移。
                putBoolean("photo_frame_branding_enabled", it.enabled)
                putString("photo_frame_watermark_content", it.content.name)
                putString("photo_frame_watermark_text", it.text)
                if (it.imageHash == null) {
                    remove("photo_frame_watermark_image_hash")
                } else {
                    putString("photo_frame_watermark_image_hash", it.imageHash)
                }
                putString("photo_frame_watermark_font", it.font.name)
                putInt("photo_frame_watermark_size", it.sizePercent)
                putInt(
                    PHOTO_FRAME_WATERMARK_SIZE_SCALE_VERSION_KEY,
                    PHOTO_FRAME_WATERMARK_SIZE_SCALE_VERSION,
                )
                putString("photo_frame_watermark_position", it.position.name)
                putString("photo_frame_watermark_color", it.color.name)
                putInt("photo_frame_watermark_opacity", it.opacityPercent)
                putString("photo_frame_watermark_effect", it.effect.name)
            }
        }.apply()
        _state.update {
            it.copy(
                photoFrameEnabled = decorationEnabled,
                photoFrameBorderEnabled = borderEnabled,
                photoFramePreset = preset,
                photoFrameWatermarkEnabled = normalized?.enabled
                    ?: it.photoFrameWatermarkEnabled,
                photoFrameWatermarkContent = normalized?.content
                    ?: it.photoFrameWatermarkContent,
                photoFrameWatermarkText = normalized?.text
                    ?: it.photoFrameWatermarkText,
                photoFrameWatermarkImageHash = if (normalized != null) {
                    normalized.imageHash
                } else {
                    it.photoFrameWatermarkImageHash
                },
                photoFrameWatermarkFont = normalized?.font
                    ?: it.photoFrameWatermarkFont,
                photoFrameWatermarkSizePercent = normalized?.sizePercent
                    ?: it.photoFrameWatermarkSizePercent,
                photoFrameWatermarkPosition = normalized?.position
                    ?: it.photoFrameWatermarkPosition,
                photoFrameWatermarkColor = normalized?.color
                    ?: it.photoFrameWatermarkColor,
                photoFrameWatermarkOpacityPercent = normalized?.opacityPercent
                    ?: it.photoFrameWatermarkOpacityPercent,
                photoFrameWatermarkEffect = normalized?.effect
                    ?: it.photoFrameWatermarkEffect,
            )
        }
    }

    fun setPhotoFilterEnabled(enabled: Boolean) {
        val canEnable = enabled && _state.value.selectedPhotoFilterId != null
        prefs.edit().putBoolean("photo_filter_enabled", canEnable).apply()
        _state.update { it.copy(photoFilterEnabled = canEnable) }
    }

    fun toggleFavoritePhotoFilter(filterId: String) {
        val catalogKey = BuiltInPhotoFilters.catalogKey(filterId) ?: return
        val current = _state.value.favoritePhotoFilters
        val updated = if (current.any { it.catalogKey == catalogKey }) {
            current.filterNot { it.catalogKey == catalogKey }
        } else {
            current + FavoritePhotoFilter(catalogKey)
        }
        persistFavoritePhotoFilters(updated)
    }

    fun rememberTransferPhotoFilterIntensity(filterId: String, intensityPercent: Int) {
        val catalogKey = BuiltInPhotoFilters.catalogKey(filterId) ?: return
        val intensity = normalizePhotoFilterIntensity(intensityPercent)
        val state = _state.value
        val intensities = state.transferPhotoFilterIntensities + (catalogKey to intensity)
        prefs.edit()
            .putString(
                PHOTO_FILTER_INTENSITIES_PREFERENCE_KEY,
                encodePhotoFilterIntensities(intensities),
            )
            .apply()
        _state.update {
            it.copy(transferPhotoFilterIntensities = intensities)
        }
    }

    fun toggleFavoriteFrameEffect(
        preset: PhotoFramePreset,
        watermark: PhotoFrameWatermark,
    ) {
        val current = _state.value.favoriteFrameEffects
        val updated = if (current.any { it.framePreset == preset }) {
            current.filterNot { it.framePreset == preset }
        } else {
            current + FavoriteFrameWatermarkEffect.capture(preset, watermark)
        }
        persistFavoriteFrameEffects(updated)
    }

    fun updateFavoriteFrameEffect(
        preset: PhotoFramePreset,
        watermark: PhotoFrameWatermark,
    ) {
        val current = _state.value.favoriteFrameEffects
        if (current.none { it.framePreset == preset }) return
        val updated = current.map { favorite ->
            if (favorite.framePreset == preset) {
                FavoriteFrameWatermarkEffect.capture(preset, watermark)
            } else {
                favorite
            }
        }
        persistFavoriteFrameEffects(updated)
    }

    private fun persistFavoritePhotoFilters(favorites: List<FavoritePhotoFilter>) {
        prefs.edit()
            .putString(
                FAVORITE_PHOTO_FILTERS_PREFERENCE_KEY,
                encodeFavoritePhotoFilters(favorites),
            )
            .apply()
        _state.update { it.copy(favoritePhotoFilters = favorites) }
    }

    private fun persistFavoriteFrameEffects(favorites: List<FavoriteFrameWatermarkEffect>) {
        prefs.edit()
            .putString(
                FAVORITE_FRAME_EFFECTS_PREFERENCE_KEY,
                encodeFavoriteFrameEffects(favorites),
            )
            .apply()
        _state.update { it.copy(favoriteFrameEffects = favorites) }
    }

    fun setPhotoFilterConfiguration(
        selectedId: String?,
        intensityPercent: Int,
        enabled: Boolean,
    ) {
        val validId = selectedId?.takeIf { id -> _state.value.photoFilters.any { it.id == id } }
        val intensity = normalizePhotoFilterIntensity(intensityPercent)
        val active = enabled && validId != null
        validId?.let { rememberTransferPhotoFilterIntensity(it, intensity) }
        prefs.edit().apply {
            if (validId == null) remove("photo_filter_selected_id")
            else putString("photo_filter_selected_id", validId)
            putBoolean("photo_filter_enabled", active)
        }.apply()
        _state.update {
            it.copy(
                selectedPhotoFilterId = validId,
                photoFilterIntensityPercent = intensity,
                photoFilterEnabled = active,
            )
        }
    }

    /**
     * 将 Photo Picker 返回的临时 URI 复制为内容寻址的私有文件。调用方只持有摘要，原图随后
     * 被移动、删除或系统回收 URI 权限，都不会影响预览和导出。
     */
    fun importPhotoFrameWatermarkImage(
        sourceUri: Uri,
        onComplete: (Result<String>) -> Unit,
    ) {
        if (!LicenseManager.isPro.value) {
            onComplete(Result.failure(IllegalStateException("Custom watermark requires Pro")))
            return
        }
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) {
                storePhotoFrameWatermarkImage(
                    context = getApplication(),
                    resolver = contentResolver,
                    sourceUri = sourceUri,
                )
            }
            onComplete(result)
        }
    }

    /** 应用内语言；写入状态后由 Compose 根节点原位替换本地化资源。 */
    fun setAppLanguage(tag: String) {
        prefs.edit().putString(AppLocale.PREF_KEY, tag).apply()
        _state.update { it.copy(appLanguage = tag) }
    }

    /** 应用筛选（类型/保护/连拍/未传输/卡槽/日期）；卡槽仅当前进程生效，其余持久化。 */
    fun setFilters(criteria: PhotoFilterCriteria) {
        prefs.edit().apply {
            if (criteria.extensions == null) remove("filter_exts")
            else putStringSet("filter_exts", criteria.extensions)
            if (criteria.protectedOnly) putBoolean("filter_protected", true) else remove("filter_protected")
            if (criteria.burstOnly) putBoolean("filter_burst", true) else remove("filter_burst")
            if (criteria.untransferredOnly) putBoolean("filter_untransferred", true)
            else remove("filter_untransferred")
            // 卡槽不跨进程保存；顺手清理旧版本可能遗留的值。
            remove("filter_storage_slot")
            if (criteria.dateRange == null) {
                remove("filter_date_start")
                remove("filter_date_end")
            } else {
                putString("filter_date_start", criteria.dateRange.start.toString())
                putString("filter_date_end", criteria.dateRange.endInclusive.toString())
            }
        }.apply()
        _state.update {
            it.copy(
                filterExtensions = criteria.extensions,
                filterProtectedOnly = criteria.protectedOnly,
                filterBurstOnly = criteria.burstOnly,
                filterUntransferredOnly = criteria.untransferredOnly,
                filterStorageSlot = criteria.storageSlot,
                filterDateRange = criteria.dateRange,
            )
        }
    }

    /** 恢复文件页的整套默认筛选；日期和以后新增的默认项都以同一快照为准。 */
    fun clearFilters() = setFilters(PhotoFilterCriteria.Default)

    fun setTransferDirUri(uri: Uri) {
        contentResolver.takePersistableUriPermission(
            uri,
            android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    android.content.Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        )
        prefs.edit().putString("transfer_dir", uri.toString()).apply()
        invalidateDirectoryIndexes()
        primeDirectoryIndexScan(uri, deleteParts = false)
        _state.update {
            it.copy(
                transferDirUri = uri.toString(),
                existingExportIndex = ExportedOriginalIndex(),
                existingExportRevision = 0L,
            )
        }
        viewModelScope.launch(Dispatchers.IO) {
            refreshExistingExportFiles(uri, deleteParts = false)
        }
    }

    /** Stores only non-default per-frame overrides; both effects editors keep separate stores. */
    fun setPhotoFrameMetadataSettings(
        preset: PhotoFramePreset,
        settings: PhotoFrameMetadataSettings?,
    ) {
        val normalized = settings?.let(::normalizePhotoFrameMetadataSettings)
        val current = _state.value.photoFrameMetadataSettings
        val updated = if (
            normalized == null || normalized == defaultPhotoFrameMetadataSettings(preset)
        ) {
            current - preset
        } else {
            current + (preset to normalized)
        }
        if (updated == current) return
        prefs.edit()
            .putString(
                PHOTO_FRAME_METADATA_SETTINGS_KEY,
                encodePhotoFrameMetadataSettings(updated),
            )
            .apply()
        _state.update { it.copy(photoFrameMetadataSettings = updated) }
    }

    private fun rootDocumentUri(treeUri: Uri): Uri =
        DocumentsContract.buildDocumentUriUsingTree(
            treeUri,
            DocumentsContract.getTreeDocumentId(treeUri),
        )

    private fun directoryIndexKey(treeUri: Uri, directoryUri: Uri): String =
        "${treeUri}|${DocumentsContract.getDocumentId(directoryUri)}"

    private fun childDirectories(treeUri: Uri, parentDirectoryUri: Uri): List<Pair<String, Uri>> {
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
            treeUri,
            DocumentsContract.getDocumentId(parentDirectoryUri),
        )
        return contentResolver.query(
            childrenUri,
            arrayOf(
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
            ),
            null,
            null,
            null,
        )?.use { cursor ->
            val nameIndex = cursor.getColumnIndexOrThrow(
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            )
            val idIndex = cursor.getColumnIndexOrThrow(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            )
            val mimeIndex = cursor.getColumnIndexOrThrow(
                DocumentsContract.Document.COLUMN_MIME_TYPE,
            )
            buildList {
                while (cursor.moveToNext()) {
                    if (cursor.getString(mimeIndex) != DocumentsContract.Document.MIME_TYPE_DIR) {
                        continue
                    }
                    val name = cursor.getString(nameIndex) ?: continue
                    val documentId = cursor.getString(idIndex) ?: continue
                    add(name to DocumentsContract.buildDocumentUriUsingTree(treeUri, documentId))
                }
            }
        }.orEmpty()
    }

    private fun getOrCreateTransferDirectory(
        treeUri: Uri,
        rootDirectoryUri: Uri,
        name: String,
    ): Uri {
        require(isDatedTransferFolderName(name))
        val key = "${treeUri}|$name"
        datedTransferDirectories[key]?.let { return it }
        return synchronized(datedTransferDirectories) {
            datedTransferDirectories[key] ?: run {
                val existing = childDirectories(treeUri, rootDirectoryUri)
                    .firstOrNull { it.first.equals(name, ignoreCase = true) }
                    ?.second
                val directory = existing ?: DocumentsContract.createDocument(
                    contentResolver,
                    rootDirectoryUri,
                    DocumentsContract.Document.MIME_TYPE_DIR,
                    name,
                ) ?: childDirectories(treeUri, rootDirectoryUri)
                    .firstOrNull { it.first.equals(name, ignoreCase = true) }
                    ?.second
                ?: throw java.io.IOException("Cannot create dated transfer directory")
                datedTransferDirectories[key] = directory
                directory
            }
        }
    }

    private fun primeDirectoryIndexScan(uri: Uri, deleteParts: Boolean) {
        val directoryUri = rootDocumentUri(uri)
        val key = directoryIndexKey(uri, directoryUri)
        synchronized(directoryIndexLock) {
            if (directoryIndexes.containsKey(key) || directoryIndexScans.containsKey(key)) return
            directoryIndexScans[key] = viewModelScope.async(Dispatchers.IO) {
                sweepAndIndexExisting(uri, directoryUri, deleteParts)
            }
        }
    }

    private suspend fun getDirectoryIndex(
        uri: Uri,
        deleteParts: Boolean = false,
    ): ExistingDirectoryIndex = getDirectoryIndex(
        treeUri = uri,
        directoryUri = rootDocumentUri(uri),
        deleteParts = deleteParts,
    )

    private suspend fun getDirectoryIndex(
        treeUri: Uri,
        directoryUri: Uri,
        deleteParts: Boolean = false,
    ): ExistingDirectoryIndex {
        val key = directoryIndexKey(treeUri, directoryUri)
        val scan = synchronized(directoryIndexLock) {
            directoryIndexes[key]?.let { return it }
            directoryIndexScans[key] ?: viewModelScope.async(Dispatchers.IO) {
                sweepAndIndexExisting(treeUri, directoryUri, deleteParts)
            }.also { directoryIndexScans[key] = it }
        }
        return try {
            val scanned = scan.await()
            synchronized(directoryIndexLock) {
                if (directoryIndexScans[key] === scan) {
                    directoryIndexScans.remove(key)
                    directoryIndexes[key] = scanned
                    scanned
                } else {
                    directoryIndexes[key] ?: scanned
                }
            }
        } catch (cancelled: CancellationException) {
            synchronized(directoryIndexLock) {
                if (directoryIndexScans[key] === scan) directoryIndexScans.remove(key)
            }
            throw cancelled
        } catch (error: Exception) {
            synchronized(directoryIndexLock) {
                if (directoryIndexScans[key] === scan) directoryIndexScans.remove(key)
            }
            throw error
        }
    }

    private fun invalidateDirectoryIndexes() = synchronized(directoryIndexLock) {
        directoryIndexes.clear()
        directoryIndexScans.clear()
        datedTransferDirectories.clear()
        photoFrameDestinations.clear()
    }

    private fun invalidateDirectoryIndex(uri: Uri) = synchronized(directoryIndexLock) {
        val prefix = "${uri}|"
        directoryIndexes.keys.removeAll { it.startsWith(prefix) }
        directoryIndexScans.keys.removeAll { it.startsWith(prefix) }
        datedTransferDirectories.keys.removeAll { it.startsWith(prefix) }
        photoFrameDestinations.keys.removeAll { it.startsWith(prefix) }
    }

    private suspend fun refreshExistingExportFiles(
        uri: Uri,
        deleteParts: Boolean,
    ) {
        try {
            val rootDirectoryUri = rootDocumentUri(uri)
            val directoryIndexes = buildList {
                add(null to getDirectoryIndex(uri, deleteParts))
                childDirectories(uri, rootDirectoryUri)
                    .asSequence()
                    .filter { isDatedTransferFolderName(it.first) }
                    .forEach { (folderName, directoryUri) ->
                        add(folderName to getDirectoryIndex(uri, directoryUri, deleteParts))
                    }
            }
            val snapshot = _state.value
            if (snapshot.transferDirUri != uri.toString()) return
            var changed = false
            directoryIndexes.forEach { (destinationFolderName, directoryIndex) ->
                if (
                    snapshot.existingExportIndex.addAll(
                        entries = directoryIndex.exportedOriginalEntries(),
                        destinationFolderName = destinationFolderName,
                    )
                ) {
                    changed = true
                }
            }
            if (changed) {
                _state.update { state ->
                    if (
                        state.transferDirUri == uri.toString() &&
                        state.existingExportIndex === snapshot.existingExportIndex
                    ) {
                        state.copy(existingExportRevision = state.existingExportRevision + 1L)
                    } else {
                        state
                    }
                }
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            // 保留扫描期间由已完成传输写入的索引；新目录初始本来就是空映射。
        }
    }

    private fun recordExistingExport(
        uri: Uri,
        destinationFolderName: String?,
        name: String,
        size: Long,
        localUri: Uri,
    ) {
        val snapshot = _state.value
        // 目录选择器在传输期间仍可能被打开；旧目录任务完成后绝不能污染新目录索引。
        if (snapshot.transferDirUri != uri.toString()) return
        if (
            !snapshot.existingExportIndex.add(
                fileName = name,
                size = size,
                destinationFolderName = destinationFolderName,
                uriString = localUri.toString(),
            )
        ) {
            return
        }
        _state.update { state ->
            if (
                state.transferDirUri == uri.toString() &&
                state.existingExportIndex === snapshot.existingExportIndex
            ) {
                state.copy(existingExportRevision = state.existingExportRevision + 1L)
            } else {
                state
            }
        }
    }

    fun addToQueue(files: List<NikonCamera.FileInfo>, cameraProvider: () -> NikonCamera?) {
        val snapshot = _state.value
        val dirUri = snapshot.transferDirUri ?: return
        val newTasks = createQueueTasks(
            files = files,
            photoFrameEnabled = snapshot.photoFrameEnabled,
            photoFrameBorderEnabled = snapshot.photoFrameBorderEnabled,
            photoFramePreset = snapshot.photoFramePreset,
            photoFrameWatermark = snapshot.photoFrameWatermark,
            photoFrameMetadataSettings = resolvedPhotoFrameMetadataSettings(
                snapshot.photoFrameMetadataSettings,
                snapshot.photoFramePreset,
            ),
            photoFilter = snapshot.photoFilterSelection,
            organizeTransfersByDate = snapshot.organizeTransfersByDate,
        )
        if (newTasks.isEmpty()) return
        _state.update { state ->
            state.withTaskStructure(state.tasks + newTasks)
        }
        pendingTransferQueue.addAll(newTasks)
        val queueState = _state.value
        if (
            shouldRunQueueAfterEnqueue(
                deferTransferStart = queueState.deferTransferStart,
                isTransferring = queueState.isTransferring,
                pauseAfterCurrent = queueState.pauseAfterCurrent,
            )
        ) {
            prewarmPhotoFilterFor(newTasks)
            processQueue(dirUri, cameraProvider)
        }
    }

    /** 自动入口不改变手动重复导出的语义，只避免同一次新增事件与现有任务撞车。 */
    fun addNewMediaToQueue(
        files: List<NikonCamera.FileInfo>,
        cameraProvider: () -> NikonCamera?,
    ): List<NikonCamera.FileInfo> {
        val snapshot = _state.value
        if (!snapshot.autoTransferNewMedia || snapshot.transferDirUri == null) return emptyList()
        if (cameraProvider() == null) return emptyList()
        val queued = snapshot.tasks.asSequence()
            .mapTo(HashSet()) { it.file.autoTransferIdentity() }
        val candidates = files.asSequence()
            .distinctBy { it.autoTransferIdentity() }
            .filterNot { it.autoTransferIdentity() in queued }
            .toList()
        if (candidates.isNotEmpty()) addToQueue(candidates, cameraProvider)
        return candidates
    }

    private fun prewarmPhotoFilterFor(tasks: Collection<TransferTask>) {
        tasks.firstNotNullOfOrNull { it.photoFilterRequested }?.let(::prewarmPhotoFilter)
    }

    /** Starts every existing WAITING task. This explicit action also releases a manual pause. */
    fun startPendingTransfers(cameraProvider: () -> NikonCamera?) {
        val snapshot = _state.value
        if (snapshot.isTransferring) return
        val dirUri = snapshot.transferDirUri ?: return
        val waiting = snapshot.tasks.filter { it.status == TransferStatus.WAITING }
        if (waiting.isEmpty()) return
        _state.update { state ->
            state.withTransferExecutionState(state.transferExecutionState.resumed())
        }
        prewarmPhotoFilterFor(waiting)
        processQueue(dirUri, cameraProvider)
    }

    /** The active task is never interrupted; the scheduler observes this before claiming the next. */
    fun requestPauseAfterCurrent() {
        _state.update { state ->
            state.withTransferExecutionState(state.transferExecutionState.pauseRequested())
        }
    }

    /**
     * 用户确认传输时便开始建立精确 RGB 映射表，让这项一次性计算与首张照片下载并行。
     * 第一张进入生成流程时只需等待尚未完成的尾段，之后同滤镜、同强度全部直接复用。
     */
    private fun prewarmPhotoFilter(selection: PhotoFilterSelection) {
        if (
            photoFilterPrewarmSelection == selection &&
            photoFilterPrewarmJob?.isActive == true
        ) {
            return
        }
        photoFilterPrewarmJob?.cancel()
        photoFilterPrewarmSelection = selection
        photoFilterPrewarmJob = viewModelScope.launch(Dispatchers.IO) {
            PhotoFilterRenderer.prepareOriginalFilter(selection) { !isActive }
        }
    }

    private fun processQueue(dirUri: String, cameraProvider: () -> NikonCamera?) {
        // 手动暂停是队列总闸门：除“开始”会先显式解除外，重试等任何旁路都不能偷偷恢复队列。
        if (_state.value.pauseAfterCurrent) return
        if (transferJob?.isActive == true) return
        val job = viewModelScope.launch(start = CoroutineStart.LAZY) {
                val self = coroutineContext[Job]
                var serviceStarted = false
                var stoppedAfterCurrent = false
                val cameraMetadataCache = mutableMapOf<Int, PhotoFrameMetadata>()

                try {
                    val uri = Uri.parse(dirUri)
                    val rootDirectoryUri = rootDocumentUri(uri)

                // 队列启动前先校验传输目录仍然存在且可访问：目录被删除/改名/换存储后，
                // 后续 createDocument 会抛 "Missing file for primary:..." 这类系统原始
                // 错误直接漏到界面上。失效则清掉设置——用户下次点图会被既有引导
                //（未设目录自动弹设置面板）带去重新选择。
                val dirValid = withContext(Dispatchers.IO) {
                    try {
                        contentResolver.query(
                            rootDirectoryUri,
                            arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID),
                            null, null, null
                        )?.use { true } ?: false
                    } catch (_: Exception) {
                        false
                    }
                }
                if (!dirValid) {
                    pendingTransferQueue.clear()
                    invalidateDirectoryIndex(uri)
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

                // 启动/选目录时已建立索引；这里复用同一单飞结果。正常连续队列不再重复
                // query SAF，后续成功文件和断点文件会增量写回该索引。
                val rootDirectoryIndex = getDirectoryIndex(uri, deleteParts = false)
                var taskToRecheck: TransferTask? = null
                while (true) {
                    // Pause is deliberately checked only at task boundaries. The current PTP
                    // object always finishes normally; no Cancel packet or socket teardown is sent.
                    if (
                        shouldPauseBeforeNextTransfer(
                            pauseAfterCurrent = _state.value.pauseAfterCurrent,
                            isRecheckingCurrentTask = taskToRecheck != null,
                        )
                    ) {
                        stoppedAfterCurrent = true
                        break
                    }
                    // 待传队列与历史展示列表分离，取下一项为 O(1)，不会随着已完成历史增长
                    // 反复从列表头扫描。同一 handle 的不同装饰任务仍由 taskId 独立标识。
                    val task = taskToRecheck?.also { taskToRecheck = null }
                        ?: pendingTransferQueue.takeFirst()
                        ?: break
                    val taskId = task.taskId
                    val handle = task.file.handle
                    val destinationDirectoryUri = task.destinationFolderName?.let { folderName ->
                        withContext(Dispatchers.IO) {
                            getOrCreateTransferDirectory(uri, rootDirectoryUri, folderName)
                        }
                    } ?: rootDirectoryUri
                    val directoryIndex = if (destinationDirectoryUri == rootDirectoryUri) {
                        rootDirectoryIndex
                    } else {
                        getDirectoryIndex(uri, destinationDirectoryUri, deleteParts = false)
                    }

                    // 第一查：原片存在就直接引用，不再区分“下载任务/边框任务”。
                    val localOriginal = directoryIndex.findOriginal(task.file)
                    if (localOriginal != null) {
                        log { "DL_SKIP existing: ${task.file.fileName}" }
                        recordExistingExport(
                            uri = uri,
                            destinationFolderName = task.destinationFolderName,
                            name = localOriginal.displayName,
                            size = localOriginal.size,
                            localUri = localOriginal.uri,
                        )
                        val preset = task.framePreset
                        val filter = task.photoFilterRequested
                        if (preset == null && filter == null) {
                            updateTask(taskId) {
                                it.copy(
                                    status = TransferStatus.COMPLETED,
                                    skipped = true,
                                    progress = 1f,
                                    downloaded = localOriginal.size,
                                    speed = 0,
                                )
                            }
                        } else {
                            // 第二查必须发生在启动前台服务之前。若派生图已经存在，任务会瞬间
                            // 完成；此时先 startForegroundService 再立即 stop，会在部分系统上
                            // 触发 ForegroundServiceDidNotStartInTimeException，直接杀掉 App。
                            val decorationRequested = preset != null
                            val effectivePreset = preset ?: PhotoFramePreset.MIST
                            val effectiveBorder = decorationRequested && task.frameBorderRequested
                            val effectiveMetadataSettings = task.frameMetadataSettings
                                ?: defaultPhotoFrameMetadataSettings(effectivePreset)
                            val effectiveWatermark = if (decorationRequested) {
                                effectivePhotoFrameWatermark(
                                    isPro = LicenseManager.isPro.value,
                                    preference = task.frameWatermarkRequested,
                                    borderEnabled = effectiveBorder,
                                )
                            } else {
                                PhotoFrameWatermark(enabled = false)
                            }
                            val frameExists = withContext(photoFrameDispatcher) {
                                val destination = getOrPreparePhotoFrameDestination(
                                    uri,
                                    destinationDirectoryUri,
                                )
                                destination.hasFrameFor(
                                    localOriginal.displayName,
                                    effectivePreset,
                                    effectiveWatermark,
                                    borderEnabled = effectiveBorder,
                                    metadataSettings = effectiveMetadataSettings,
                                    filter = filter,
                                )
                            }
                            // 预检查挂起期间用户可能撤回这项；此时不得继续派生或传输。
                            if (pendingTransferQueue.consumeWithdrawal(taskId)) continue
                            if (frameExists) {
                                log {
                                        "DERIVATIVE_SKIP existing: ${localOriginal.displayName} " +
                                        "border=$effectiveBorder preset=${effectivePreset.name} " +
                                        "filter=${filter?.preset?.name}"
                                }
                                updateTask(taskId) {
                                    it.copy(
                                        status = TransferStatus.COMPLETED,
                                        skipped = true,
                                        progress = 1f,
                                        downloaded = localOriginal.size,
                                        speed = 0,
                                    )
                                }
                                continue
                            }
                            updateTask(taskId) {
                                it.copy(
                                    status = TransferStatus.COMPLETED,
                                    progress = 1f,
                                    downloaded = localOriginal.size,
                                    speed = 0,
                                ).startFrameGeneration(android.os.SystemClock.elapsedRealtime())
                            }
                            if (!serviceStarted) {
                                TransferService.start(getApplication(), useWifi = false)
                                serviceStarted = true
                            }
                            val cameraMetadata = if (effectiveBorder &&
                                isJpegPhotoName(task.file.fileName)
                            ) {
                                cameraMetadataCache[task.file.handle] ?: readCameraFrameMetadataHeader(
                                    camera = cameraProvider(),
                                    handle = task.file.handle,
                                    mode = "existing",
                                )?.let { header ->
                                    withContext(Dispatchers.Default) {
                                        parseCameraFrameMetadata(header, mode = "existing")
                                    }
                                }?.also { cameraMetadataCache[task.file.handle] = it }
                            } else {
                                null
                            }
                            launchPhotoFrameExport(
                                taskId = taskId,
                                treeUri = uri,
                                destinationParentUri = destinationDirectoryUri,
                                sourceUri = localOriginal.uri,
                                sourceName = localOriginal.displayName,
                                preset = effectivePreset,
                                borderEnabled = effectiveBorder,
                                metadataSettings = effectiveMetadataSettings,
                                watermarkRequested = task.frameWatermarkRequested,
                                decorationRequested = decorationRequested,
                                filterRequested = filter,
                                skipIfExisting = true,
                                failTaskOnError = true,
                                cameraMetadata = cameraMetadata,
                            )
                        }
                        continue
                    }

                    // 免费版每日完成数已达上限：不再开始新传输，卡片直接标注并引导解锁。
                    // 检查放在"已存在跳过"之后——跳过不占额度，到了上限也照常放行。
                    if (LicenseManager.transferLimitReached()) {
                        updateTask(taskId) {
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
                        updateTask(taskId) {
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
                        updateTask(taskId) {
                            it.copy(status = TransferStatus.FAILED, error = str(R.string.camera_not_connected), speed = 0)
                        }
                        continue
                    }

                    // 断点续传：检查是否存在上次传输留下的、【身份令牌匹配】的半成品文件。
                    var resumeOffset = 0L
                    var fileDocUri: Uri? = null
                    val partFile = directoryIndex.partFor(task.file.fileName)
                        ?.takeIf { it.token == identityToken(task.file) }
                    if (partFile != null) {
                        val partSize = partFile.size
                        val partPlan = planExistingPart(
                            objectSize = task.file.size,
                            partSize = partSize,
                        )
                        if (partPlan.action == ExistingPartAction.FINALIZE_COMPLETE_PART) {
                            // 半成品与完整大小严格相等：上次下载完在改名前崩了，直接改名跳过下载。
                            // 仅在大小【已知】时走此捷径——SIZE_UNKNOWN 下 partSize>=哨兵会把
                            // 4.3GB 的截断视频误判为完整，造成静默数据丢失。
                            log { "DL_RESUME_COMPLETE: ${task.file.fileName} partSize=$partSize" }
                            val finalName = task.file.fileName
                            var renamed = renameQuietly(partFile.uri, finalName)
                            if (renamed == null) {
                                // 改名失败：复用已有副本逻辑
                                for (n in 1..99) {
                                    val candidate = suffixedTransferFileName(finalName, n)
                                    if (directoryIndex.containsDisplayName(candidate)) continue
                                    renamed = renameQuietly(partFile.uri, candidate)
                                    if (renamed != null) break
                                }
                            }
                            if (renamed != null) {
                                val savedName = displayNameOf(renamed) ?: finalName
                                directoryIndex.addFile(savedName, partSize, renamed)
                                directoryIndex.removePart(task.file.fileName)
                                recordExistingExport(
                                    uri = uri,
                                    destinationFolderName = task.destinationFolderName,
                                    name = savedName,
                                    size = partSize,
                                    localUri = renamed,
                                )
                                if (pendingTransferQueue.consumeWithdrawal(taskId)) continue
                                // 回到循环顶部，统一走“原片存在 → 检查边框”的同一条路径。
                                // 使用本地槽立即复查，不能放回队尾改变用户看到的 FIFO 顺序。
                                taskToRecheck = task
                                continue
                            } else {
                                // 改不了，删半成品让正常路径重下
                                deleteQuietly(partFile.uri)
                                directoryIndex.removePart(task.file.fileName)
                            }
                        } else if (partPlan.action == ExistingPartAction.RESUME_FROM_PART) {
                            // 半成品够大（≥1 块）且未完整：从块边界续传。大小未知(>4GB)也允许——
                            // 由协议层用 GetObjectSize 解析真实大小后做全文件完整性校验。
                            resumeOffset = partPlan.resumeOffset
                            fileDocUri = partFile.uri
                            log { "DL_RESUME: ${task.file.fileName} partSize=$partSize resumeOffset=$resumeOffset" }
                        } else {
                            // 不足一个续传块（当前 4MB）或异常半成品，删掉重建。
                            deleteQuietly(partFile.uri)
                            directoryIndex.removePart(task.file.fileName)
                        }
                    }

                    // 断点改名/清理会切到 IO 线程；任务在这期间仍显示 WAITING，用户可以撤回。
                    // 所有这类预处理结束后统一消费撤回标记，绝不能把 CANCELLED 再改回传输中。
                    if (pendingTransferQueue.consumeWithdrawal(taskId)) continue

                    // 完成所有“无需下载即可结束”的检查后，才进入传输态并发布高频进度，
                    // 避免完整断点文件仅改名时出现假进度或前台通知闪动。
                    updateTask(taskId) { it.copy(status = TransferStatus.TRANSFERING) }
                    _activeTransferProgress.value = ActiveTransferProgress(
                        taskId = taskId,
                        retainedBytesPerSecond = lastValidTransferSpeed,
                    )
                    log { "DL_BEGIN: ${task.file.fileName} handle=$handle size=${task.file.size}" }

                    // 首个真正要下载的文件才拉起前台服务（全部命中"已存在"时不必启动，避免通知闪一下）。
                    if (!serviceStarted) {
                        TransferService.start(
                            getApplication(),
                            useWifi = camera.connectionType == CameraConnectionType.WIFI
                        )
                        serviceStarted = true
                    }

                    try {
                        var cameraHeaderPrefix: ByteArray? = null
                        // SAF 的建文件/开流/关闭冲刷都是跨进程 Binder + 磁盘 IO，放 IO 线程，
                        // 不在主线程随每个文件抖一下（状态更新经 StateFlow.update，线程安全）。
                        val result = withContext(Dispatchers.IO) {
                            if (fileDocUri == null) {
                                // 新建临时文件
                                val createdUri = DocumentsContract.createDocument(
                                    contentResolver,
                                    destinationDirectoryUri,
                                    transferMimeType(task.file.fileName),
                                    partFileName(task.file)
                                ) ?: throw Exception(str(R.string.error_create_file))
                                fileDocUri = createdUri
                                directoryIndex.addPart(
                                    task.file.fileName,
                                    PartInfo(
                                        uri = createdUri,
                                        size = 0L,
                                        token = identityToken(task.file),
                                    ),
                                )
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
                            val downloadResult = java.io.BufferedOutputStream(
                                outputStream,
                                1024 * 1024,
                            ).use { out ->
                                camera.downloadToFile(
                                    handle, out,
                                    onProgress = { progress ->
                                        val speed = progress.bytesPerSecond
                                        val retainedSpeed = retainLastValidTransferSpeed(
                                            previous = lastValidTransferSpeed,
                                            sample = speed,
                                        )
                                        lastValidTransferSpeed = retainedSpeed
                                        _activeTransferProgress.update { active ->
                                            if (active?.taskId != taskId) return@update active
                                            active.copy(
                                                fraction = if (progress.total > 0) {
                                                    (progress.downloaded.toDouble() / progress.total)
                                                        .toFloat()
                                                        .coerceIn(0f, 1f)
                                                } else {
                                                    0f
                                                },
                                                downloaded = progress.downloaded,
                                                bytesPerSecond = speed,
                                                retainedBytesPerSecond = retainedSpeed,
                                            )
                                        }
                                    },
                                    resumeOffset = resumeOffset,
                                    totalSize = task.file.size,
                                    // 协议层在首个数据命令前读取一次，随后整张文件固定该策略。
                                    preferHighThroughputAtStart = { preferHighThroughputTransfers },
                                    captureHeader = task.framePreset != null &&
                                        task.frameBorderRequested &&
                                        isJpegPhotoName(task.file.fileName),
                                )
                            }
                            cameraHeaderPrefix = downloadResult.getOrNull()?.headerPrefix
                            downloadResult
                        }
                        // withContext 正常返回则 fileDocUri 必已赋值。
                        val createdUri = checkNotNull(fileDocUri)
                        // Parse the small immutable metadata object in parallel with the provider
                        // rename/copy below. This releases the 256 KiB prefix promptly instead of
                        // retaining one byte array per queued frame task.
                        val cameraMetadataDeferred = cameraHeaderPrefix?.let { header ->
                            async(Dispatchers.Default) {
                                parseCameraFrameMetadata(header, mode = "download")
                            }
                        }

                        result.fold(
                            onSuccess = { stats ->
                                PhotoGenerationProbe.note(
                                    category = "FRAME-META",
                                    message = "original download complete bytes=${stats.bytes} " +
                                        "headerBytes=${cameraHeaderPrefix?.size ?: 0}",
                                )
                                // 下载完整 → 把临时名改成真正文件名（相机上报的文件名即为准）。
                                val finalName = task.file.fileName
                                var savedName = finalName
                                var originalSaveMode = if (renameBroken) "full_copy" else "rename"
                                var renamedUri = if (renameBroken) null else renameQuietly(createdUri, finalName)
                                if (renamedUri == null && !renameBroken) {
                                    for (n in 1..99) {
                                        val candidate = suffixedTransferFileName(finalName, n)
                                        if (directoryIndex.containsDisplayName(candidate)) continue
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
                                    if (directoryIndex.containsDisplayName(copyName)) {
                                        for (n in 1..99) {
                                            val candidate = suffixedTransferFileName(finalName, n)
                                            if (!directoryIndex.containsDisplayName(candidate)) {
                                                copyName = candidate
                                                break
                                            }
                                        }
                                    }
                                    val copied = copyAsFallback(
                                        destinationDirectoryUri, createdUri, copyName,
                                        transferMimeType(finalName), stats.bytes
                                    )
                                    val copiedUri = copied.getOrNull()
                                    if (copiedUri != null) {
                                        renameBroken = true
                                        originalSaveMode = "full_copy"
                                        deleteQuietly(createdUri)
                                        savedName = displayNameOf(copiedUri) ?: copyName
                                        renamedUri = copiedUri
                                        log { "DL_SAVE via copy fallback: $savedName (rename broken)" }
                                    } else {
                                        saveError = copied.exceptionOrNull()
                                    }
                                }
                                if (renamedUri != null) {
                                    PhotoGenerationProbe.note(
                                        category = "FRAME-META",
                                        message = "original saved mode=$originalSaveMode " +
                                            "name=$savedName bytes=${stats.bytes}",
                                    )
                                    directoryIndex.addFile(savedName, stats.bytes, renamedUri)
                                    directoryIndex.removePart(task.file.fileName)
                                    recordExistingExport(
                                        uri = uri,
                                        destinationFolderName = task.destinationFolderName,
                                        name = savedName,
                                        size = stats.bytes,
                                        localUri = renamedUri,
                                    )
                                    val framePreset = task.framePreset
                                    val photoFilter = task.photoFilterRequested
                                    val shouldGenerateFrame = framePreset != null || photoFilter != null
                                    // 起点由协议层在本文件进入下载流程时记录（包含为大图/EXIF
                                    // 让路的块间时间）；这里仍是正式文件已落盘并完成改名/复制后的完成点。
                                    val elapsed = android.os.SystemClock.elapsedRealtime() -
                                        stats.startedAtElapsedMs
                                    val endToEndMBps = endToEndBytesPerSecond(
                                        transferredBytes = stats.transferredBytes,
                                        elapsedMs = elapsed,
                                    ) / (1024f * 1024f)
                                    // 免费额度按"真正传输完成"计数(此处是唯一完成点;
                                    // 跳过/续传改名捷径都不经过这里,不计)。
                                    LicenseManager.recordTransferDone()
                                    updateTask(taskId) {
                                        it.copy(
                                            status = TransferStatus.COMPLETED, progress = 1f,
                                            downloaded = stats.bytes, speed = 0,
                                            downloadMBps = endToEndMBps,
                                            elapsedMs = elapsed,
                                        ).let { completed ->
                                            if (shouldGenerateFrame) {
                                                completed.startFrameGeneration(
                                                    android.os.SystemClock.elapsedRealtime(),
                                                )
                                            } else {
                                                completed
                                            }
                                        }
                                    }
                                    if (shouldGenerateFrame) {
                                        var cameraMetadata = cameraMetadataCache[task.file.handle]
                                            ?: cameraMetadataDeferred?.await()
                                        if (resumeOffset > 0 && framePreset != null &&
                                            task.frameBorderRequested &&
                                            isJpegPhotoName(task.file.fileName) &&
                                            cameraMetadata == null
                                        ) {
                                            cameraMetadata = readCameraFrameMetadataHeader(
                                                camera = camera,
                                                handle = task.file.handle,
                                                mode = "resume",
                                            )?.let { header ->
                                                withContext(Dispatchers.Default) {
                                                    parseCameraFrameMetadata(
                                                        header,
                                                        mode = "resume",
                                                    )
                                                }
                                            }
                                        }
                                        cameraMetadata?.let {
                                            cameraMetadataCache[task.file.handle] = it
                                        }
                                        // 派生严格发生在正式原片落盘之后。导出器只读取原片并创建
                                        // 新文件；独立低优先级工作池立即接管，传输循环直接处理下一张。
                                        // 无论解码/写入是否失败，都不回滚、不删除原片。
                                        launchPhotoFrameExport(
                                            taskId = taskId,
                                            treeUri = uri,
                                            destinationParentUri = destinationDirectoryUri,
                                            sourceUri = renamedUri,
                                            sourceName = savedName,
                                            preset = framePreset ?: PhotoFramePreset.MIST,
                                            borderEnabled = framePreset != null &&
                                                task.frameBorderRequested,
                                            metadataSettings = task.frameMetadataSettings
                                                ?: defaultPhotoFrameMetadataSettings(
                                                    framePreset ?: PhotoFramePreset.MIST,
                                                ),
                                            watermarkRequested = task.frameWatermarkRequested,
                                            decorationRequested = framePreset != null,
                                            filterRequested = photoFilter,
                                            skipIfExisting = true,
                                            cameraMetadata = cameraMetadata,
                                        )
                                    }
                                } else {
                                    // 改名与复制均失败：删掉临时文件并标记失败——
                                    // 重试时从头下载（改名失败不是传输层问题，续传解决不了）。
                                    deleteQuietly(createdUri)
                                    directoryIndex.removePart(task.file.fileName)
                                    val reason = when {
                                        saveError is java.io.FileNotFoundException ->
                                            str(R.string.error_dir_invalid)
                                        saveError?.message != null -> saveError.message
                                        else -> str(R.string.error_rename_copy_refused)
                                    }
                                    updateTask(taskId) {
                                        it.copy(status = TransferStatus.FAILED, error = str(R.string.error_save_failed, reason), speed = 0)
                                    }
                                }
                            },
                            onFailure = { e ->
                                if (
                                    failedPartAction(e is ResumeUnavailableException) ==
                                    FailedPartAction.DELETE_BEFORE_FRESH_RETRY
                                ) {
                                    // 走不了续传（相机不支持分块 / >4GB 拿不到真实大小）：删掉半成品，
                                    // 本次标记失败，重试将从头全新下载——绝不用错位的全量数据续写。
                                    deleteQuietly(fileDocUri)
                                    directoryIndex.removePart(task.file.fileName)
                                    updateTask(taskId) {
                                        it.copy(status = TransferStatus.FAILED, error = str(R.string.transfer_failed), speed = 0)
                                    }
                                } else {
                                    // 普通传输失败：保留半成品，重试时从块边界续传。
                                    // 不删 .nkpart_：断点续传依赖它，交给 App 启动 init 的 sweep 统一清扫。
                                    refreshPartIndexForRetry(
                                        directoryIndex = directoryIndex,
                                        file = task.file,
                                        partUri = fileDocUri,
                                    )
                                    updateTask(taskId) {
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
                        refreshPartIndexForRetry(
                            directoryIndex = directoryIndex,
                            file = task.file,
                            partUri = fileDocUri,
                        )
                        updateTask(taskId) {
                            it.copy(status = TransferStatus.FAILED, error = friendlyError(e), speed = 0)
                        }
                    }
                }
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Exception) {
                    pendingTransferQueue.clear()
                    invalidateDirectoryIndex(Uri.parse(dirUri))
                    // 目录 URI 解析、目录扫描等位于单任务 try/catch 之外。任何 provider
                    // 异常都只能让相关卡片失败，不能成为主线程未捕获异常导致 App 闪退。
                    if (BuildConfig.DEBUG) {
                        android.util.Log.e(
                            TAG,
                            "QUEUE_FAIL: ${error.javaClass.simpleName}: ${error.message}",
                            error,
                        )
                    }
                    val message = friendlyError(error)
                    val activeProgress = _activeTransferProgress.value
                    _state.update { state ->
                        state.copy(tasks = state.tasks.map { task ->
                            if (
                                task.status == TransferStatus.WAITING ||
                                task.status == TransferStatus.TRANSFERING
                            ) {
                                task.withActiveProgress(activeProgress).copy(
                                    status = TransferStatus.FAILED,
                                    error = message,
                                    speed = 0,
                                )
                            } else {
                                task
                            }
                        })
                    }
                } finally {
                    // 仅当本协程仍是当前传输 job 时才收尾，避免误停新队列的前台服务/误清传输
                    // 状态（旧队列收尾期间新队列可能已启动并接管 transferJob）。
                    if (transferJob === self) {
                        if (!stoppedAfterCurrent) pendingTransferQueue.clear()
                        _activeTransferProgress.value = null
                        lastValidTransferSpeed = 0L
                        _state.update { state ->
                            state.withTransferExecutionState(
                                state.transferExecutionState.finished(stoppedAfterCurrent),
                            )
                        }
                        stopTransferServiceIfIdle()
                    }
                }
        }
        transferJob = job
        // Publish the running state before starting the lazy coroutine. Auto-start enqueue and the
        // deferred pill therefore cannot expose a one-frame false paused state.
        _state.update { state ->
            state.withTransferExecutionState(state.transferExecutionState.started())
        }
        job.start()
    }

    /**
     * 单次遍历目标目录：
     * 1) 当 [deleteParts]=true 时删除遗留的半成品（[TRANSFER_PART_PREFIX] 开头的临时文件，上次崩溃/被杀留下）；
     *    同时删除旧进程遗留的边框临时文件；当前进程会话的边框任务始终保留；
     * 2) 返回完整文件的 显示名->大小/Uri，用于"已存在则跳过"及已传原片的本地派生；
     * 3) 收集半成品文件信息到 parts 映射（原文件名 -> PartInfo），用于断点续传。
     * 合并清扫与列举，避免两次全目录扫描；正常完成的文件已改真名，不会被误删。
     *
     * @param deleteParts true=清空半成品（App 启动/新队列）, false=保留半成品供续传（队列启动重试）
     * @return 完整文件大小、Uri 与半成品映射的一致快照
     */
    private fun sweepAndIndexExisting(
        treeUri: Uri,
        directoryUri: Uri,
        deleteParts: Boolean = true
    ): ExistingDirectoryIndex {
        val index = ExistingDirectoryIndex()
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
            treeUri,
            DocumentsContract.getDocumentId(directoryUri),
        )
        val cursor = contentResolver.query(
                childrenUri,
                arrayOf(
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                    DocumentsContract.Document.COLUMN_SIZE,
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                    DocumentsContract.Document.COLUMN_MIME_TYPE,
                ),
                null, null, null
            ) ?: throw java.io.IOException("Directory provider returned no cursor")
        cursor.use { c ->
                val nameIdx = c.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                val sizeIdx = c.getColumnIndex(DocumentsContract.Document.COLUMN_SIZE)
                val idIdx = c.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                val mimeIdx = c.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)
                if (nameIdx < 0 || idIdx < 0) {
                    throw java.io.IOException("Directory provider omitted required columns")
                }
                while (c.moveToNext()) {
                        val name = c.getString(nameIdx) ?: continue
                        if (
                            mimeIdx >= 0 &&
                            c.getString(mimeIdx) == DocumentsContract.Document.MIME_TYPE_DIR
                        ) {
                            continue
                        }
                        if (name.startsWith(PHOTO_FRAME_PART_PREFIX)) {
                            // 边框派生临时文件不可续传：App 启动时清理；队列运行期间
                            // 只忽略不删除，避免新队列扫描误删仍在后台写入的旧队列任务。
                            if (
                                deleteParts &&
                                !isCurrentPhotoFrameTempName(name)
                            ) {
                                val docId = c.getString(idIdx) ?: continue
                                runCatching {
                                    DocumentsContract.deleteDocument(
                                        contentResolver,
                                        DocumentsContract.buildDocumentUriUsingTree(treeUri, docId),
                                    )
                                }
                            }
                        } else if (name.startsWith(TRANSFER_PART_PREFIX)) {
                            if (deleteParts) {
                                val docId = c.getString(idIdx) ?: continue
                                try {
                                    DocumentsContract.deleteDocument(
                                        contentResolver,
                                        DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)
                                    )
                                } catch (_: Exception) {}
                            } else {
                                // 续传模式：保留半成品，解析出身份令牌与原文件名（按首个下划线切分）。
                                val docId = c.getString(idIdx) ?: continue
                                val size = if (sizeIdx >= 0 && !c.isNull(sizeIdx)) c.getLong(sizeIdx) else 0L
                                parseTransferPartFileName(name)?.let { partName ->
                                    index.addPart(
                                        partName.originalFileName,
                                        PartInfo(
                                            uri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId),
                                            size = size,
                                            token = partName.identityToken,
                                        ),
                                    )
                                }
                                // 旧格式/异常半成品名不记录（App 启动 init sweep 会清掉）。
                            }
                        } else {
                            val size = if (sizeIdx >= 0 && !c.isNull(sizeIdx)) c.getLong(sizeIdx) else -1L
                            val docId = c.getString(idIdx)
                            if (docId != null) {
                                index.addFile(
                                    displayName = name,
                                    size = size,
                                    uri = DocumentsContract.buildDocumentUriUsingTree(
                                        treeUri,
                                        docId,
                                    ),
                                )
                            }
                        }
                }
            }
        return index
    }

    /** 失败后只查询这一份半成品的大小并更新缓存；不为一次重试重扫整个目录。 */
    private suspend fun refreshPartIndexForRetry(
        directoryIndex: ExistingDirectoryIndex,
        file: NikonCamera.FileInfo,
        partUri: Uri?,
    ) {
        if (partUri == null) return
        val size = withContext(Dispatchers.IO) {
            try {
                contentResolver.query(
                    partUri,
                    arrayOf(DocumentsContract.Document.COLUMN_SIZE),
                    null,
                    null,
                    null,
                )?.use { cursor ->
                    if (cursor.moveToFirst() && !cursor.isNull(0)) cursor.getLong(0) else 0L
                }
            } catch (_: Exception) {
                null
            }
        }
        if (size == null) {
            directoryIndex.removePart(file.fileName)
            return
        }
        directoryIndex.addPart(
            file.fileName,
            PartInfo(partUri, size.coerceAtLeast(0L), identityToken(file)),
        )
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
            if (!isOriginalFileCopyComplete(copiedBytes, expectedBytes)) {
                throw Exception(str(R.string.error_copy_incomplete, copiedBytes, expectedBytes))
            }
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

    /** 从相机读取效果图所需的 JPEG 文件头；失败只影响派生图，不回滚已落盘原片。 */
    private suspend fun readCameraFrameMetadataHeader(
        camera: NikonCamera?,
        handle: Int,
        mode: String,
    ): ByteArray? {
        PhotoGenerationProbe.note(
            category = "FRAME-META",
            message = "header request mode=$mode handle=$handle maxBytes=262144 " +
                "camera=${camera != null}",
        )
        val header = try {
            camera?.readExifHeader(handle, maxSize = 256 * 1024)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            PhotoGenerationProbe.note(
                category = "FRAME-META",
                message = "header error mode=$mode type=${error.javaClass.simpleName}",
            )
            null
        }
        PhotoGenerationProbe.note(
            category = "FRAME-META",
            message = "header result mode=$mode bytes=${header?.size ?: 0}",
        )
        return header
    }

    private fun parseCameraFrameMetadata(
        header: ByteArray,
        mode: String,
    ): PhotoFrameMetadata? {
        val metadata = PhotoFrameExporter.metadataFromExifHeader(null, header)
        val hasCoordinates = metadata.latitude?.isFinite() == true &&
            metadata.longitude?.isFinite() == true &&
            metadata.latitude != 0.0 && metadata.longitude != 0.0 &&
            metadata.latitude in -90.0..90.0 && metadata.longitude in -180.0..180.0
        val hasAltitude = metadata.altitudeMeters?.isFinite() == true &&
            metadata.altitudeMeters != 0.0
        val hasCameraField = sequenceOf(
            metadata.make,
            metadata.model,
            metadata.aperture,
            metadata.shutter,
            metadata.iso,
            metadata.focalLength,
            metadata.lensModel,
            metadata.dateTime,
        ).any { !it.isNullOrBlank() }
        return metadata.takeIf { hasCameraField || hasCoordinates || hasAltitude }.also { parsed ->
            if (parsed == null) {
                PhotoGenerationProbe.note(
                    category = "FRAME-META",
                    message = "header parse empty mode=$mode bytes=${header.size}",
                )
            }
        }
    }

    private fun PhotoFrameMetadataSettings.hasVisibleMetadata(): Boolean =
        showDate || showTime || showFocalLength || showExposure || showBrand || showModel ||
            showLensModel || showCoordinates || showAltitude

    private fun isJpegPhotoName(name: String): Boolean {
        val extension = name.substringAfterLast('.', "")
        return extension.equals("jpg", ignoreCase = true) ||
            extension.equals("jpeg", ignoreCase = true)
    }

    /**
     * 把原片派生移出相机传输协程。双线程工作池提供受控并行，低线程优先级让相机 IO
     * 优先；任务数单独计数，使最后一张效果图完成前前台服务不会被提前停止。
     */
    private fun launchPhotoFrameExport(
        taskId: Long,
        treeUri: Uri,
        destinationParentUri: Uri,
        sourceUri: Uri,
        sourceName: String,
        preset: PhotoFramePreset,
        borderEnabled: Boolean,
        metadataSettings: PhotoFrameMetadataSettings,
        watermarkRequested: PhotoFrameWatermark,
        decorationRequested: Boolean = true,
        filterRequested: PhotoFilterSelection? = null,
        skipIfExisting: Boolean = false,
        failTaskOnError: Boolean = false,
        cameraMetadata: PhotoFrameMetadata? = null,
    ) {
        val probeStartedAtMs = if (PhotoGenerationProbe.enabled) {
            android.os.SystemClock.elapsedRealtime()
        } else {
            0L
        }
        val probeSession = if (PhotoGenerationProbe.enabled) {
            PhotoGenerationProbe.begin(
                sourceName = sourceName,
                configuration = buildString {
                    append("preset=${preset.name} border=$borderEnabled")
                    append(" filter=${filterRequested?.preset?.name ?: "none"}")
                    filterRequested?.let { append(" intensity=${it.normalizedIntensityPercent}") }
                },
            )
        } else {
            PhotoGenerationProbe.NO_SESSION
        }
        PhotoGenerationProbe.frameNote(
            sessionId = probeSession,
            category = "FRAME-PIPE",
            message = "start source=$sourceName uri=$sourceUri preset=${preset.name} " +
                "border=$borderEnabled fields=${metadataSettings.showAddress}/" +
                "${metadataSettings.showCoordinates}/${metadataSettings.showAltitude} " +
                "filter=${filterRequested?.preset?.name ?: "none"} " +
                "cameraMetadata=${cameraMetadata != null}",
        )
        var probeOutcome = "cancelled"
        var frameExportSaved = false
        activePhotoFrameExports.incrementAndGet()
        val job = viewModelScope.launch(photoFrameDispatcher) {
            if (PhotoGenerationProbe.enabled) {
                PhotoGenerationProbe.stage(
                    sessionId = probeSession,
                    name = "worker_wait",
                    durationMs = android.os.SystemClock.elapsedRealtime() - probeStartedAtMs,
                )
            }
            val destinationKey = "${treeUri}|${destinationParentUri}"
            val outcome = try {
                val destinationWasCached = photoFrameDestinations.containsKey(destinationKey)
                val destinationStartedAtMs = if (PhotoGenerationProbe.enabled) {
                    android.os.SystemClock.elapsedRealtime()
                } else {
                    0L
                }
                val destination = getOrPreparePhotoFrameDestination(
                    treeUri,
                    destinationParentUri,
                )
                if (PhotoGenerationProbe.enabled) {
                    PhotoGenerationProbe.stage(
                        sessionId = probeSession,
                        name = "destination_prepare",
                        durationMs = android.os.SystemClock.elapsedRealtime() - destinationStartedAtMs,
                        detail = "cached=$destinationWasCached",
                    )
                }
                // 在真正轮到渲染时重新判定授权：排队期间若高级版到期，免费版默认
                // 水印立即恢复；查重与导出必须使用同一份生效配置。
                val effectiveBorder = decorationRequested && borderEnabled
                val effectiveWatermark = if (decorationRequested) {
                    effectivePhotoFrameWatermark(
                        isPro = LicenseManager.isPro.value,
                        preference = watermarkRequested,
                        borderEnabled = effectiveBorder,
                    )
                } else {
                    PhotoFrameWatermark(enabled = false)
                }
                if (
                    skipIfExisting &&
                    destination.hasFrameFor(
                        sourceName,
                        preset,
                        effectiveWatermark,
                        borderEnabled = effectiveBorder,
                        metadataSettings = metadataSettings,
                        filter = filterRequested,
                    )
                ) {
                    FrameExportOutcome.AlreadyExists
                } else if (effectiveBorder && isJpegPhotoName(sourceName) &&
                    metadataSettings.hasVisibleMetadata() &&
                    cameraMetadata == null
                ) {
                    FrameExportOutcome.Failed(
                        IllegalStateException(str(R.string.error_camera_metadata_unavailable)),
                    )
                } else {
                    PhotoGenerationProbe.frameNote(
                        sessionId = probeSession,
                        category = "FRAME-EXPORT",
                        message = "begin source=$sourceName " +
                            "fields=${metadataSettings.showAddress}/" +
                            "${metadataSettings.showCoordinates}/${metadataSettings.showAltitude}",
                    )
                    log {
                        "DERIVATIVE_BEGIN: $sourceName source=$sourceUri " +
                            "fields=${metadataSettings.showAddress}/" +
                            "${metadataSettings.showCoordinates}/${metadataSettings.showAltitude}"
                    }
                    PhotoFrameExporter.export(
                        context = getApplication(),
                        resolver = contentResolver,
                        destination = destination,
                        sourceUri = sourceUri,
                        sourceName = sourceName,
                        preset = preset,
                        watermark = effectiveWatermark,
                        borderEnabled = effectiveBorder,
                        metadataSettings = metadataSettings,
                        filter = filterRequested,
                        probeSessionId = probeSession,
                        metadataSnapshot = cameraMetadata,
                        allowLocalMetadataRead = false,
                    ).fold(
                        onSuccess = { FrameExportOutcome.Saved(it.displayName) },
                        onFailure = { FrameExportOutcome.Failed(it) },
                    )
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                FrameExportOutcome.Failed(error)
            }
            probeOutcome = when (outcome) {
                is FrameExportOutcome.Saved -> "saved"
                FrameExportOutcome.AlreadyExists -> "already_exists"
                is FrameExportOutcome.Failed ->
                    "failed:${outcome.error.javaClass.simpleName}"
            }
            frameExportSaved = outcome is FrameExportOutcome.Saved
            when (outcome) {
                is FrameExportOutcome.Saved -> {
                    log { "DERIVATIVE_SAVE: $sourceName -> ${outcome.displayName}" }
                }
                FrameExportOutcome.AlreadyExists -> {
                    PhotoGenerationProbe.frameNote(
                        sessionId = probeSession,
                        category = "FRAME-EXPORT",
                        message = "skipped existing source=$sourceName " +
                            "fields=${metadataSettings.showAddress}/" +
                            "${metadataSettings.showCoordinates}/${metadataSettings.showAltitude}",
                    )
                    log {
                        "DERIVATIVE_SKIP existing: $sourceName " +
                            "border=$borderEnabled preset=${preset.name} " +
                            "fields=${metadataSettings.showAddress}/" +
                            "${metadataSettings.showCoordinates}/${metadataSettings.showAltitude}"
                    }
                    updateTask(taskId) { task ->
                        task.copy(
                            status = TransferStatus.COMPLETED,
                            skipped = true,
                            error = null,
                        )
                    }
                }
                is FrameExportOutcome.Failed -> {
                    // 子目录若被用户在运行期间删除，下一个任务重新查找/创建。
                    photoFrameDestinations.remove(destinationKey)
                    log {
                        "DERIVATIVE_FAILED: $sourceName " +
                            "${outcome.error.javaClass.simpleName}: ${outcome.error.message}"
                    }
                    if (failTaskOnError) {
                        updateTask(taskId) { task ->
                            task.copy(
                                status = TransferStatus.FAILED,
                                error = friendlyError(outcome.error),
                                speed = 0,
                            )
                        }
                    }
                }
            }
        }
        // invokeOnCompletion 即使任务排队期间就被取消也必定执行，计数和 UI 不会泄漏。
        job.invokeOnCompletion { cause ->
            if (cause != null) {
                probeOutcome = if (cause is CancellationException) {
                    "cancelled:${cause.javaClass.simpleName}"
                } else {
                    "aborted:${cause.javaClass.simpleName}"
                }
            }
            if (PhotoGenerationProbe.enabled) {
                PhotoGenerationProbe.finish(
                    sessionId = probeSession,
                    outcome = probeOutcome,
                    totalMs = android.os.SystemClock.elapsedRealtime() - probeStartedAtMs,
                )
            }
            updateTask(taskId) { task ->
                val finished = task.finishFrameGeneration(
                    android.os.SystemClock.elapsedRealtime(),
                )
                if (frameExportSaved) {
                    finished
                } else {
                    finished.copy(frameGenerationElapsedMs = null)
                }
            }
            if (activePhotoFrameExports.decrementAndGet() == 0) {
                stopTransferServiceIfIdle()
            }
        }
    }

    private fun stopTransferServiceIfIdle() {
        if (!_state.value.isTransferring && activePhotoFrameExports.get() == 0) {
            TransferService.stop(getApplication())
        }
    }

    /** 按 taskId 更新单个低频任务状态；活动下载的高频进度在独立 StateFlow 中。 */
    private fun updateTask(taskId: Long, transform: (TransferTask) -> TransferTask) {
        val activeProgress = _activeTransferProgress.value?.takeIf { it.taskId == taskId }
        _state.update { state ->
            val index = state.tasks.indexOfFirst { it.taskId == taskId }
            if (index < 0) return@update state
            val current = state.tasks[index]
            val updated = transform(current.withActiveProgress(activeProgress))
            if (updated == current) return@update state
            val tasks = state.tasks.toMutableList()
            tasks[index] = updated
            state.copy(tasks = tasks)
        }
    }

    private inline fun log(message: () -> String) {
        if (BuildConfig.DEBUG) android.util.Log.d(TAG, message())
    }

    /**
     * 撤下所有等待中的任务（WAITING→CANCELLED），队列协程不会再开始它们；
     * 正在传输的文件让它自然传完——中途打断需要发 PTP/IP Cancel 包或直接断开连接，
     * 实测两者都会让相机挂起会话甚至关闭 Wi-Fi，代价远高于传完当前文件。
     * 队列协程发现没有 WAITING 任务后自然收尾（isTransferring 复位、前台服务停止）。
     * "清空队列"的第一步：先撤下，UI 播完移除动画后再逐个 [removeTask]。
     */
    fun withdrawPending() {
        val waitingTaskIds = _state.value.tasks.asSequence()
            .filter { it.status == TransferStatus.WAITING }
            .mapTo(HashSet()) { it.taskId }
        pendingTransferQueue.withdraw(waitingTaskIds)
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
    fun withdrawTask(taskId: Long) {
        if (_state.value.tasks.any {
                it.taskId == taskId && it.status == TransferStatus.WAITING
            }
        ) {
            pendingTransferQueue.withdraw(listOf(taskId))
        }
        _state.update { state ->
            state.copy(
                tasks = state.tasks.map {
                    if (it.taskId == taskId && it.status == TransferStatus.WAITING) {
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
     * 与 [removeTask] 同规则：TRANSFERING/WAITING/正在生成派生图的一律保留。
     */
    fun removeCleared() {
        _state.update { state ->
            val kept = state.tasks.filter {
                it.status == TransferStatus.TRANSFERING ||
                    it.status == TransferStatus.WAITING ||
                    it.isGeneratingFrame
            }
            if (kept.size == state.tasks.size) {
                state
            } else {
                state.withTaskStructure(kept)
            }
        }
    }

    /**
     * 把任务卡片从队列移除（移除动画结束后调用），返回是否真的移除了。
     * 拒绝移除 TRANSFERING（正在传输）与 WAITING（动画期间被"重试"重置回等待，
     * 说明用户想要它了），以及正在生成派生图的任务——竞态下调用方把卡片弹回原高即可。
     * 合法移除路径上任务必为 CANCELLED/COMPLETED/FAILED（等待中的在标记时已 withdraw）。
     */
    fun removeTask(taskId: Long): Boolean {
        var removed = false
        _state.update { state ->
            val kept = state.tasks.filterNot {
                it.taskId == taskId &&
                        it.status != TransferStatus.TRANSFERING &&
                        it.status != TransferStatus.WAITING &&
                        !it.isGeneratingFrame
            }
            removed = kept.size != state.tasks.size
            if (removed) {
                state.withTaskStructure(kept)
            } else {
                state
            }
        }
        return removed
    }

    /**
     * 重试失败/取消的任务：保留入队时锁定的边框与水印配置，只创建新的任务 ID
     * 并重置运行状态。这样用户切换设置后，重试仍然得到入队时选定的派生图。
     */
    fun retryFailed(
        cameraProvider: () -> NikonCamera?,
        excludedTaskIds: Set<Long> = emptySet(),
    ) {
        val snapshot = _state.value
        val dirUri = snapshot.transferDirUri ?: return
        val retryIds = retryableTransferTaskIds(snapshot.tasks, excludedTaskIds)
        if (retryIds.isEmpty()) return
        val attemptsByOldTaskId = snapshot.tasks.asSequence()
            .filter { it.taskId in retryIds }
            .associate { it.taskId to it.newAttempt() }
        _state.update { state ->
            val updatedTasks = state.tasks.map {
                if (
                    it.taskId in retryIds &&
                    (it.status == TransferStatus.FAILED || it.status == TransferStatus.CANCELLED)
                ) {
                    attemptsByOldTaskId.getValue(it.taskId)
                } else {
                    it
                }
            }
            if (updatedTasks.indices.any { updatedTasks[it].taskId != state.tasks[it].taskId }) {
                state.withTaskStructure(updatedTasks)
            } else {
                state
            }
        }
        val appliedTaskIds = _state.value.tasks.asSequence().mapTo(HashSet()) { it.taskId }
        val appliedAttempts = attemptsByOldTaskId.values.filter {
            it.taskId in appliedTaskIds
        }
        if (appliedAttempts.isNotEmpty()) {
            pendingTransferQueue.addAll(appliedAttempts)
            if (!_state.value.pauseAfterCurrent) {
                prewarmPhotoFilterFor(appliedAttempts)
                processQueue(dirUri, cameraProvider)
            }
        }
    }

    /** 同 [retryFailed]：只重置指定任务，绝不影响同一照片的其它边框任务。 */
    fun retrySingleTask(taskId: Long, cameraProvider: () -> NikonCamera?) {
        val snapshot = _state.value
        val task = snapshot.tasks.firstOrNull { it.taskId == taskId } ?: return
        if (task.status != TransferStatus.FAILED && task.status != TransferStatus.CANCELLED) return
        val dirUri = snapshot.transferDirUri ?: return
        val attempt = task.newAttempt()
        _state.update { state ->
            val updatedTasks = state.tasks.map {
                if (
                    it.taskId == taskId &&
                    (it.status == TransferStatus.FAILED || it.status == TransferStatus.CANCELLED)
                ) {
                    attempt
                } else {
                    it
                }
            }
            if (updatedTasks.indices.any { updatedTasks[it].taskId != state.tasks[it].taskId }) {
                state.withTaskStructure(updatedTasks)
            } else {
                state
            }
        }
        if (_state.value.tasks.any { it.taskId == attempt.taskId }) {
            pendingTransferQueue.addAll(listOf(attempt))
            if (!_state.value.pauseAfterCurrent) {
                prewarmPhotoFilterFor(listOf(attempt))
                processQueue(dirUri, cameraProvider)
            }
        }
    }

    override fun onCleared() {
        super.onCleared()
        transferJob?.cancel()
        photoFilterPrewarmJob?.cancel()
        pendingTransferQueue.clear()
        invalidateDirectoryIndexes()
        photoFrameDispatcher.close()
        // 兜底停止前台服务，防止 VM 销毁后通知残留。
        TransferService.stop(getApplication())
    }
}
