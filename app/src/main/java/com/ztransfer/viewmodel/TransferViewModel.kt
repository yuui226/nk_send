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
import com.ztransfer.frame.PhotoFrameDestination
import com.ztransfer.frame.PhotoFrameExporter
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
import com.ztransfer.frame.normalizePhotoFrameWatermarkOpacityPercent
import com.ztransfer.frame.normalizePhotoFrameWatermarkSizePercent
import com.ztransfer.frame.importPhotoFrameWatermarkImage as storePhotoFrameWatermarkImage
import com.ztransfer.frame.photoFrameWatermarkImageFile
import com.ztransfer.frame.validPhotoFrameWatermarkImageHash
import com.ztransfer.filter.PhotoFilterPreset
import com.ztransfer.filter.BuiltInPhotoFilters
import com.ztransfer.filter.PhotoFilterSelection
import com.ztransfer.filter.normalizePhotoFilterIntensity
import com.ztransfer.license.LicenseManager
import com.ztransfer.protocol.CameraConnectionType
import com.ztransfer.protocol.NikonCamera
import com.ztransfer.protocol.PtpConstants
import com.ztransfer.protocol.ResumeUnavailableException
import com.ztransfer.service.TransferService
import com.ztransfer.ui.theme.SkinPreset
import com.ztransfer.ui.theme.ThemeMode
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

enum class TransferStatus {
    WAITING, TRANSFERING, COMPLETED, FAILED, CANCELLED
}

private val transferTaskIds = AtomicLong(0L)

data class TransferTask(
    val file: NikonCamera.FileInfo,
    /** 队列任务的进程内唯一标识；同一相机文件可以按不同装饰配置创建多个独立任务。 */
    val taskId: Long = transferTaskIds.incrementAndGet(),
    /** 入队时锁定的边框样式；null 表示该任务不生成边框/水印派生图。 */
    val framePreset: PhotoFramePreset? = null,
    /** false 表示保留原照片画布，仅叠加画面内水印。 */
    val frameBorderRequested: Boolean = true,
    /** 与预设同时快照，避免排队期间修改设置改变已入队任务的输出。 */
    val frameWatermarkRequested: PhotoFrameWatermark = PhotoFrameWatermark(),
    /** 入队时锁定的滤镜；与边框互相独立，null 表示原片不做颜色处理。 */
    val photoFilterRequested: PhotoFilterSelection? = null,
    val status: TransferStatus = TransferStatus.WAITING,
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
)

private fun TransferTask.newAttempt(): TransferTask = copy(
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
)

data class TransferState(
    val tasks: List<TransferTask> = emptyList(),
    val isTransferring: Boolean = false,
    val currentSpeed: Long = 0,
    val transferDirUri: String? = null,
    /** 导出目录内完整文件：归一化文件名 -> 已有大小集合，用于相机列表直接标记已传照片。 */
    val existingExportFiles: Map<String, Set<Long>> = emptyMap(),
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
    // 预览大图的全局逆时针旋转方向（0..3 个 90°）。跨照片、跨会话持久化。
    val previewRotationQuarterTurns: Int = 0,
    // 开启后：受支持的原图落盘成功，再派生一张带边框和/或水印的分享图。
    val photoFrameEnabled: Boolean = false,
    // 总开关开启时，边框与水印可以独立组合；false 允许只在原照片上叠水印。
    val photoFrameBorderEnabled: Boolean = true,
    // 启用边框时采用的默认样式。派生图只另存新文件，永不覆盖原片。
    val photoFramePreset: PhotoFramePreset = PhotoFramePreset.MIST,
    // 自定义水印。免费版渲染时强制使用默认值；高级版可关闭和调整，并记住选择。
    val photoFrameWatermarkEnabled: Boolean = true,
    val photoFrameWatermarkContent: PhotoFrameWatermarkContent = PhotoFrameWatermarkContent.TEXT,
    val photoFrameWatermarkText: String = "ZTransfer",
    val photoFrameWatermarkImageHash: String? = null,
    val photoFrameWatermarkFont: PhotoFrameWatermarkFont = PhotoFrameWatermarkFont.ELEGANT,
    val photoFrameWatermarkSizePercent: Int = DEFAULT_PHOTO_FRAME_WATERMARK_SIZE_PERCENT,
    val photoFrameWatermarkPosition: PhotoFrameWatermarkPosition = PhotoFrameWatermarkPosition.AUTO,
    val photoFrameWatermarkColor: PhotoFrameWatermarkColor = PhotoFrameWatermarkColor.ADAPTIVE,
    val photoFrameWatermarkOpacityPercent: Int = DEFAULT_PHOTO_FRAME_WATERMARK_OPACITY_PERCENT,
    val photoFrameWatermarkEffect: PhotoFrameWatermarkEffect = PhotoFrameWatermarkEffect.AUTO,
    val photoFilters: List<PhotoFilterPreset> = emptyList(),
    val photoFilterEnabled: Boolean = false,
    val selectedPhotoFilterId: String? = null,
    val photoFilterIntensityPercent: Int = 100,
    // 监看页是否使用应用内横屏全屏布局。跨进页、跨应用重启持久化。
    val remoteRotation: Int = 0,  // 0=竖屏, 1=横90°, 2=横270°
    // 应用内语言：BCP-47 标签（"en"/"zh-Hans"/"zh-Hant"）或 AppLocale.SYSTEM（跟随系统）。
    // 切换后由设置面板触发 Activity.recreate() 生效。
    val appLanguage: String = AppLocale.SYSTEM
)

internal fun normalizeThumbnailColumns(columns: Int): Int = columns.coerceIn(2, 4)

/** 兼容旧版 SMALL/MEDIUM/LARGE 字符串，并让升级前的实际像素大小保持不变。 */
internal fun restoredPhotoFrameWatermarkSizePercent(
    persisted: Any?,
    content: PhotoFrameWatermarkContent,
): Int {
    val rawPercent = when (persisted) {
        is Number -> persisted.toInt()
        is String -> persisted.toIntOrNull() ?: when (persisted) {
            "SMALL" -> if (content == PhotoFrameWatermarkContent.IMAGE) 47 else 58
            "MEDIUM" -> if (content == PhotoFrameWatermarkContent.IMAGE) 69 else 75
            "LARGE" -> 100
            else -> DEFAULT_PHOTO_FRAME_WATERMARK_SIZE_PERCENT
        }
        else -> DEFAULT_PHOTO_FRAME_WATERMARK_SIZE_PERCENT
    }
    return normalizePhotoFrameWatermarkSizePercent(rawPercent)
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

internal val TransferState.photoFilterSelection: PhotoFilterSelection?
    get() {
        if (!photoFilterEnabled) return null
        val preset = photoFilters.firstOrNull { it.id == selectedPhotoFilterId } ?: return null
        return PhotoFilterSelection(preset, photoFilterIntensityPercent)
    }

/** 队列剩余待处理数量（正在传、等待传或正在生成派生图）。供顶栏药丸等复用。 */
val TransferState.remainingCount: Int
    get() = tasks.count {
        it.status == TransferStatus.WAITING ||
            it.status == TransferStatus.TRANSFERING ||
            it.isGeneratingFrame
    }

/**
 * 当前处理项的进度（0..1）。派生图没有廉价而准确的分段进度，原片已完整落盘后保持满格，
 * 直到派生完成；这样顶栏不会在最后一步从 100% 倒退到 0%。
 */
val TransferState.currentFileProgress: Float
    get() = tasks.firstOrNull { it.status == TransferStatus.TRANSFERING }?.progress
        ?: if (tasks.any { it.isGeneratingFrame }) 1f else 0f

/** 免费版固定使用默认水印；高级版完整采用用户设置。预览和真正导出必须共用该入口。 */
internal fun effectivePhotoFrameWatermark(
    isPro: Boolean,
    preference: PhotoFrameWatermark,
    borderEnabled: Boolean = true,
): PhotoFrameWatermark {
    val permitted = if (isPro) preference else PhotoFrameWatermark()
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
            PhotoFrameWatermarkPosition.PHOTO_BOTTOM_RIGHT
        } else {
            permitted.position
        },
    )
}

/** 只允许 JPG/JPEG/PNG 派生分享图；视频、RAW 和未知类型始终保持原样传输。 */
internal fun shouldGeneratePhotoFrame(enabled: Boolean, extension: String): Boolean =
    enabled && isSupportedPhotoFrameSourceExtension(extension)

/** 相机文件是否已在当前保存目录中落盘；列表对号、筛选和任务模式必须共用该判定。 */
internal fun isTransferredOriginal(
    file: NikonCamera.FileInfo,
    existingExportFiles: Map<String, Set<Long>>,
): Boolean {
    val sizes = existingExportFiles[file.fileName] ?: return false
    return sizes.any { it < 0L || it == file.size } ||
        file.size == PtpConstants.SIZE_UNKNOWN
}

internal fun createQueueTasks(
    files: List<NikonCamera.FileInfo>,
    photoFrameEnabled: Boolean,
    photoFrameBorderEnabled: Boolean = true,
    photoFramePreset: PhotoFramePreset,
    photoFrameWatermark: PhotoFrameWatermark,
    photoFilter: PhotoFilterSelection? = null,
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
            frameWatermarkRequested = photoFrameWatermark,
            photoFilterRequested = photoFilter.takeIf {
                isSupportedPhotoFrameSourceExtension(file.extension)
            },
        )
    }
    .toList()

class TransferViewModel(application: Application) : AndroidViewModel(application) {
    private val _state = MutableStateFlow(TransferState())
    val state: StateFlow<TransferState> = _state.asStateFlow()

    private var transferJob: Job? = null
    private val prefs = application.getSharedPreferences("ztransfer", Context.MODE_PRIVATE)
    private val contentResolver = application.contentResolver
    /**
     * 边框渲染使用独立、低优先级、单并发线程：与下一张相机传输并行，但不会同时展开
     * 多张 3200px 位图争抢内存。相机网络/USB 传输仍留在原来的高优先级通道。
     */
    private val photoFrameDispatcher = Executors.newSingleThreadExecutor { task ->
        Thread(
            {
                android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_BACKGROUND)
                task.run()
            },
            "photo-frame-export",
        )
    }.asCoroutineDispatcher()
    private val activePhotoFrameExports = AtomicInteger(0)
    // 第一张派生图才创建/扫描专用子目录；同一根目录后续任务复用，避免逐张遍历文件夹。
    private val photoFrameDestinations =
        ConcurrentHashMap<String, PhotoFrameDestination>()

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

    private data class ExistingDirectoryScan(
        val sizes: MutableMap<String, Long>,
        val uris: MutableMap<String, Uri>,
        val parts: Map<String, PartInfo>,
    )

    private data class LocalOriginal(
        val displayName: String,
        val size: Long,
        val uri: Uri,
    )

    private sealed interface FrameExportOutcome {
        data class Saved(val displayName: String) : FrameExportOutcome
        data class Failed(val error: Throwable) : FrameExportOutcome
        object AlreadyExists : FrameExportOutcome
    }

    /** 文件内容身份令牌：大小+拍摄时间，仅留字母数字与点（内嵌半成品名，不含下划线分隔符）。 */
    private fun identityToken(file: NikonCamera.FileInfo): String =
        "${file.size}.${file.captureDate ?: "0"}".replace(Regex("[^A-Za-z0-9.]"), "")

    /** 半成品文件名 = 前缀 + 身份令牌 + "_" + 原文件名（原名可含下划线，解析按【首个】下划线切分）。 */
    private fun partFileName(file: NikonCamera.FileInfo): String =
        PART_PREFIX + identityToken(file) + "_" + file.fileName

    init {
        val dir = prefs.getString("transfer_dir", null)
        val restoredPhotoFilters = BuiltInPhotoFilters.all
        val storedPhotoFilterId = prefs.getString("photo_filter_selected_id", null)
        val restoredPhotoFilterId = storedPhotoFilterId
            ?.takeIf { id -> restoredPhotoFilters.any { it.id == id } }
            ?: restoredPhotoFilters.firstOrNull()?.id
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
        val storedWatermarkSize = storedPreferences["photo_frame_watermark_size"]
        val restoredWatermarkSizePercent = restoredPhotoFrameWatermarkSizePercent(
            storedWatermarkSize,
            restoredWatermarkContent,
        )
        val storedWatermarkOpacity = storedPreferences["photo_frame_watermark_opacity"]
        val restoredWatermarkOpacityPercent =
            restoredPhotoFrameWatermarkOpacityPercent(storedWatermarkOpacity)
        val sizeNeedsMigration = storedWatermarkSize != null &&
            (storedWatermarkSize !is Number ||
                storedWatermarkSize.toInt() != restoredWatermarkSizePercent)
        val opacityNeedsMigration = storedWatermarkOpacity != null &&
            (storedWatermarkOpacity !is Number ||
                storedWatermarkOpacity.toInt() != restoredWatermarkOpacityPercent)
        if (sizeNeedsMigration || opacityNeedsMigration) {
            prefs.edit()
                .putInt("photo_frame_watermark_size", restoredWatermarkSizePercent)
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
                themeMode = prefs.getString("theme_mode", null)
                    ?.let { m -> ThemeMode.entries.firstOrNull { e -> e.name == m } }
                    ?: ThemeMode.SYSTEM,
                skinPreset = restoredSkinPreset,
                // getStringSet 返回的实例不可直接持有（SharedPreferences 约定），拷贝一份。
                filterExtensions = prefs.getStringSet("filter_exts", null)?.toSet(),
                filterProtectedOnly = prefs.getBoolean("filter_protected", false),
                filterBurstOnly = prefs.getBoolean("filter_burst", false),
                filterUntransferredOnly = prefs.getBoolean("filter_untransferred", false),
                previewRotationQuarterTurns = Math.floorMod(
                    prefs.getInt("preview_rotation_quarter_turns", 0), 4
                ),
                photoFrameEnabled = prefs.getBoolean("photo_frame_enabled", false),
                photoFrameBorderEnabled = prefs.getBoolean("photo_frame_border_enabled", true),
                photoFramePreset = runCatching {
                    PhotoFramePreset.valueOf(
                        prefs.getString("photo_frame_preset", PhotoFramePreset.MIST.name)
                            ?: PhotoFramePreset.MIST.name
                    )
                }.getOrDefault(PhotoFramePreset.MIST),
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
                            PhotoFrameWatermarkFont.ELEGANT.name,
                        ) ?: PhotoFrameWatermarkFont.ELEGANT.name,
                    )
                }.getOrDefault(PhotoFrameWatermarkFont.ELEGANT),
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
                photoFilterEnabled = storedPhotoFilterId == restoredPhotoFilterId &&
                    prefs.getBoolean("photo_filter_enabled", false),
                selectedPhotoFilterId = restoredPhotoFilterId,
                photoFilterIntensityPercent = normalizePhotoFilterIntensity(
                    prefs.getInt("photo_filter_intensity", 100),
                ),
                remoteRotation = prefs.getInt("remote_rotation", 0),
                appLanguage = prefs.getString(AppLocale.PREF_KEY, AppLocale.SYSTEM) ?: AppLocale.SYSTEM
            )
        }
        // 开 App 时清扫上次崩溃/被杀留下的半成品（.nkpart_ 临时文件）。
        if (dir != null) {
            viewModelScope.launch(Dispatchers.IO) {
                refreshExistingExportFiles(Uri.parse(dir), deleteParts = true)
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

    /** 保存预览大图的全局旋转方向；任何照片和下次启动都复用。 */
    fun setPreviewRotationQuarterTurns(turns: Int) {
        val normalized = Math.floorMod(turns, 4)
        prefs.edit().putInt("preview_rotation_quarter_turns", normalized).apply()
        _state.update { it.copy(previewRotationQuarterTurns = normalized) }
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
            ?.let {
                effectivePhotoFrameWatermark(
                    isPro = true,
                    preference = it,
                    borderEnabled = borderEnabled,
                )
            }
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

    fun setPhotoFilterConfiguration(
        selectedId: String?,
        intensityPercent: Int,
        enabled: Boolean,
    ) {
        val validId = selectedId?.takeIf { id -> _state.value.photoFilters.any { it.id == id } }
        val intensity = normalizePhotoFilterIntensity(intensityPercent)
        val active = enabled && validId != null
        prefs.edit().apply {
            if (validId == null) remove("photo_filter_selected_id")
            else putString("photo_filter_selected_id", validId)
            putInt("photo_filter_intensity", intensity)
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

    /** 保存监看页的应用内横屏状态；不改变 Android Activity 的系统方向。 */
    fun setRemoteRotation(rotation: Int) {
        prefs.edit().putInt("remote_rotation", rotation).apply()
        _state.update { it.copy(remoteRotation = rotation) }
    }

    /** 应用内语言；写入后需 Activity.recreate() 才对界面生效（attachBaseContext 重读偏好）。 */
    fun setAppLanguage(tag: String) {
        prefs.edit().putString(AppLocale.PREF_KEY, tag).apply()
        _state.update { it.copy(appLanguage = tag) }
    }

    /** 应用筛选（类型/保护/连拍/未传输，面板点击后即时提交）。持久化。 */
    fun setFilters(
        exts: Set<String>?,
        protectedOnly: Boolean,
        burstOnly: Boolean,
        untransferredOnly: Boolean
    ) {
        prefs.edit().apply {
            if (exts == null) remove("filter_exts") else putStringSet("filter_exts", exts)
            if (protectedOnly) putBoolean("filter_protected", true) else remove("filter_protected")
            if (burstOnly) putBoolean("filter_burst", true) else remove("filter_burst")
            if (untransferredOnly) putBoolean("filter_untransferred", true) else remove("filter_untransferred")
        }.apply()
        _state.update {
            it.copy(
                filterExtensions = exts,
                filterProtectedOnly = protectedOnly,
                filterBurstOnly = burstOnly,
                filterUntransferredOnly = untransferredOnly
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
        _state.update { it.copy(transferDirUri = uri.toString(), existingExportFiles = emptyMap()) }
        viewModelScope.launch(Dispatchers.IO) { refreshExistingExportFiles(uri, deleteParts = false) }
    }

    private fun refreshExistingExportFiles(uri: Uri, deleteParts: Boolean) {
        try {
            val existing = sweepAndListExisting(uri, deleteParts).sizes
            val normalized = HashMap<String, MutableSet<Long>>()
            existing.forEach { (name, size) ->
                // 派生图只参与边框输出的文件名防冲突，不参与“相机原片已传”状态。
                // 否则每传一张 JPG 都会让 Compose 持有的索引多一项，目录越大越浪费。
                if (
                    !isPhotoFrameOutputName(name) &&
                    !name.equals(PHOTO_FRAME_OUTPUT_DIRECTORY, ignoreCase = true)
                ) {
                    normalized.getOrPut(baseName(name)) { HashSet() }.add(size)
                }
            }
            _state.update { state ->
                if (state.transferDirUri == uri.toString()) {
                    // 扫描期间可能已有新传输完成并写入索引；合并而不是覆盖，避免慢扫描
                    // 用启动时的旧目录快照抹掉刚完成文件的绿勾。
                    state.existingExportFiles.forEach { (name, sizes) ->
                        normalized.getOrPut(name) { HashSet() }.addAll(sizes)
                    }
                    state.copy(existingExportFiles = normalized.mapValues { it.value.toSet() })
                } else state
            }
        } catch (_: Exception) {
            // 保留扫描期间由已完成传输写入的索引；新目录初始本来就是空映射。
        }
    }

    private fun recordExistingExport(uri: Uri, name: String, size: Long) {
        val normalizedName = baseName(name)
        _state.update { state ->
            // 目录选择器在传输期间仍可能被打开；旧目录任务完成后绝不能污染新目录索引。
            if (state.transferDirUri != uri.toString()) return@update state
            val sizes = state.existingExportFiles[normalizedName].orEmpty() + size
            state.copy(existingExportFiles = state.existingExportFiles + (normalizedName to sizes))
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
            photoFilter = snapshot.photoFilterSelection,
        )
        if (newTasks.isEmpty()) return
        _state.update { state -> state.copy(tasks = state.tasks + newTasks) }
        processQueue(dirUri, cameraProvider)
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
                val directoryScan = withContext(Dispatchers.IO) {
                    sweepAndListExisting(uri, deleteParts = false)
                }
                val existing = directoryScan.sizes
                val existingUris = directoryScan.uris
                val partFiles = directoryScan.parts
                while (true) {
                    // taskId 标识队列任务；handle 只用于与相机通信。同一 handle 可以有多张
                    // 不同装饰配置的任务卡，任何状态更新都不能再按 handle 批量命中。
                    val task = _state.value.tasks.firstOrNull { it.status == TransferStatus.WAITING } ?: break
                    val taskId = task.taskId
                    val handle = task.file.handle

                    // 第一查：原片存在就直接引用，不再区分“下载任务/边框任务”。
                    val localOriginal = findLocalOriginal(
                        file = task.file,
                        existingSizes = existing,
                        existingUris = existingUris,
                    )
                    if (localOriginal != null) {
                        log { "DL_SKIP existing: ${task.file.fileName}" }
                        recordExistingExport(uri, localOriginal.displayName, localOriginal.size)
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
                            val effectiveWatermark = if (decorationRequested) {
                                effectivePhotoFrameWatermark(
                                    isPro = LicenseManager.isPro.value,
                                    preference = task.frameWatermarkRequested,
                                    borderEnabled = effectiveBorder,
                                )
                            } else {
                                PhotoFrameWatermark(enabled = false)
                            }
                            val destinationKey = uri.toString()
                            val frameExists = withContext(photoFrameDispatcher) {
                                val destination = photoFrameDestinations[destinationKey]
                                    ?: PhotoFrameExporter.prepareDestination(
                                        resolver = contentResolver,
                                        treeUri = uri,
                                    ).let { prepared ->
                                        photoFrameDestinations.putIfAbsent(
                                            destinationKey,
                                            prepared,
                                        ) ?: prepared
                                    }
                                destination.hasFrameFor(
                                    localOriginal.displayName,
                                    effectivePreset,
                                    effectiveWatermark,
                                    borderEnabled = effectiveBorder,
                                    filter = filter,
                                )
                            }
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
                                    isGeneratingFrame = true,
                                )
                            }
                            if (!serviceStarted) {
                                TransferService.start(getApplication(), useWifi = false)
                                serviceStarted = true
                            }
                            launchPhotoFrameExport(
                                taskId = taskId,
                                treeUri = uri,
                                sourceUri = localOriginal.uri,
                                sourceName = localOriginal.displayName,
                                preset = effectivePreset,
                                borderEnabled = effectiveBorder,
                                watermarkRequested = task.frameWatermarkRequested,
                                decorationRequested = decorationRequested,
                                filterRequested = filter,
                                skipIfExisting = true,
                                failTaskOnError = true,
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

                    updateTask(taskId) { it.copy(status = TransferStatus.TRANSFERING) }
                    log { "DL_BEGIN: ${task.file.fileName} handle=$handle size=${task.file.size}" }

                    // 首个真正要下载的文件才拉起前台服务（全部命中"已存在"时不必启动，避免通知闪一下）。
                    if (!serviceStarted) {
                        TransferService.start(
                            getApplication(),
                            useWifi = camera.connectionType == CameraConnectionType.WIFI
                        )
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
                                val savedName = displayNameOf(renamed) ?: finalName
                                existing[savedName] = partSize
                                existingUris[savedName] = renamed
                                recordExistingExport(uri, savedName, partSize)
                                // 回到循环顶部，统一走“原片存在 → 检查边框”的同一条路径。
                                continue
                            } else {
                                // 改不了，删半成品让正常路径重下
                                deleteQuietly(partFile.uri)
                            }
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
                                                    if (t.taskId == taskId && t.status == TransferStatus.TRANSFERING) {
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
                                    existingUris[savedName] = renamedUri
                                    recordExistingExport(uri, savedName, stats.bytes)
                                    val framePreset = task.framePreset
                                    val photoFilter = task.photoFilterRequested
                                    val shouldGenerateFrame = framePreset != null || photoFilter != null
                                    // 起点由协议层在取得相机 IO 独占权后记录；这里仍是正式文件
                                    // 已落盘并完成改名/复制后的完成点。
                                    val elapsed = android.os.SystemClock.elapsedRealtime() -
                                        stats.startedAtElapsedMs
                                    // 免费额度按"真正传输完成"计数(此处是唯一完成点;
                                    // 跳过/续传改名捷径都不经过这里,不计)。
                                    LicenseManager.recordTransferDone()
                                    updateTask(taskId) {
                                        it.copy(
                                            status = TransferStatus.COMPLETED, progress = 1f,
                                            downloaded = stats.bytes, speed = 0,
                                            downloadMBps = stats.mbps,
                                            elapsedMs = elapsed,
                                            isGeneratingFrame = shouldGenerateFrame,
                                        )
                                    }
                                    if (shouldGenerateFrame) {
                                        // 派生严格发生在正式原片落盘之后。导出器只读取原片并创建
                                        // 新文件；独立低优先级线程立即接管，传输循环直接处理下一张。
                                        // 无论解码/写入是否失败，都不回滚、不删除原片。
                                        launchPhotoFrameExport(
                                            taskId = taskId,
                                            treeUri = uri,
                                            sourceUri = renamedUri,
                                            sourceName = savedName,
                                            preset = framePreset ?: PhotoFramePreset.MIST,
                                            borderEnabled = framePreset != null &&
                                                task.frameBorderRequested,
                                            watermarkRequested = task.frameWatermarkRequested,
                                            decorationRequested = framePreset != null,
                                            filterRequested = photoFilter,
                                            skipIfExisting = true,
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
                                    updateTask(taskId) {
                                        it.copy(status = TransferStatus.FAILED, error = str(R.string.error_save_failed, reason), speed = 0)
                                    }
                                }
                            },
                            onFailure = { e ->
                                if (e is ResumeUnavailableException) {
                                    // 走不了续传（相机不支持分块 / >4GB 拿不到真实大小）：删掉半成品，
                                    // 本次标记失败，重试将从头全新下载——绝不用错位的全量数据续写。
                                    deleteQuietly(fileDocUri)
                                    updateTask(taskId) {
                                        it.copy(status = TransferStatus.FAILED, error = str(R.string.transfer_failed), speed = 0)
                                    }
                                } else {
                                    // 普通传输失败：保留半成品，重试时从块边界续传。
                                    // 不删 .nkpart_：断点续传依赖它，交给 App 启动 init 的 sweep 统一清扫。
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
                        updateTask(taskId) {
                            it.copy(status = TransferStatus.FAILED, error = friendlyError(e), speed = 0)
                        }
                    }
                }
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Exception) {
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
                    _state.update { state ->
                        state.copy(tasks = state.tasks.map { task ->
                            if (
                                task.status == TransferStatus.WAITING ||
                                task.status == TransferStatus.TRANSFERING
                            ) {
                                task.copy(
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
                        _state.update { it.copy(isTransferring = false, currentSpeed = 0) }
                        stopTransferServiceIfIdle()
                    }
                }
        }
    }

    /**
     * 单次遍历目标目录：
     * 1) 当 [deleteParts]=true 时删除遗留的半成品（[PART_PREFIX] 开头的临时文件，上次崩溃/被杀留下）；
     *    同时删除旧进程遗留的边框临时文件；当前进程会话的边框任务始终保留；
     * 2) 返回完整文件的 显示名->大小/Uri，用于"已存在则跳过"及已传原片的本地派生；
     * 3) 收集半成品文件信息到 parts 映射（原文件名 -> PartInfo），用于断点续传。
     * 合并清扫与列举，避免两次全目录扫描；正常完成的文件已改真名，不会被误删。
     *
     * @param deleteParts true=清空半成品（App 启动/新队列）, false=保留半成品供续传（队列启动重试）
     * @return 完整文件大小、Uri 与半成品映射的一致快照
     */
    private fun sweepAndListExisting(
        treeUri: Uri,
        deleteParts: Boolean = true
    ): ExistingDirectoryScan {
        val map = HashMap<String, Long>()
        val uris = HashMap<String, Uri>()
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
                        if (name.startsWith(PHOTO_FRAME_PART_PREFIX)) {
                            // 边框派生临时文件不可续传：App 启动时清理；队列运行期间
                            // 只忽略不删除，避免新队列扫描误删仍在后台写入的旧队列任务。
                            if (
                                deleteParts &&
                                !isCurrentPhotoFrameTempName(name) &&
                                idIdx >= 0
                            ) {
                                val docId = c.getString(idIdx) ?: continue
                                runCatching {
                                    DocumentsContract.deleteDocument(
                                        contentResolver,
                                        DocumentsContract.buildDocumentUriUsingTree(treeUri, docId),
                                    )
                                }
                            }
                        } else if (name.startsWith(PART_PREFIX)) {
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
                            if (idIdx >= 0) {
                                val docId = c.getString(idIdx)
                                if (docId != null) {
                                    uris[name] = DocumentsContract.buildDocumentUriUsingTree(
                                        treeUri,
                                        docId,
                                    )
                                }
                            }
                        }
                    }
                }
            }
        } catch (_: Exception) {}
        return ExistingDirectoryScan(sizes = map, uris = uris, parts = parts)
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

    /** 从本次目录快照中找到已传原片；优先精确文件名，其次接受同大小的重名副本。 */
    private fun findLocalOriginal(
        file: NikonCamera.FileInfo,
        existingSizes: Map<String, Long>,
        existingUris: Map<String, Uri>,
    ): LocalOriginal? {
        fun sizeMatches(localSize: Long): Boolean =
            localSize < 0L ||
                file.size == PtpConstants.SIZE_UNKNOWN ||
                localSize == file.size

        val exactSize = existingSizes[file.fileName]
        val exactUri = existingUris[file.fileName]
        if (exactSize != null && exactUri != null && sizeMatches(exactSize)) {
            return LocalOriginal(file.fileName, exactSize, exactUri)
        }

        return existingSizes.entries.firstNotNullOfOrNull { (displayName, size) ->
            val localUri = existingUris[displayName] ?: return@firstNotNullOfOrNull null
            if (baseName(displayName).equals(file.fileName, ignoreCase = true) && sizeMatches(size)) {
                LocalOriginal(displayName, size, localUri)
            } else {
                null
            }
        }
    }

    /** 生成重名副本名："DSC_0001.NEF" + 2 -> "DSC_0001 (2).NEF"；无扩展名则直接追加。 */
    private fun suffixedName(name: String, n: Int): String {
        val dot = name.lastIndexOf('.')
        return if (dot <= 0) "$name ($n)" else "${name.substring(0, dot)} ($n)${name.substring(dot)}"
    }

    /**
     * 把原片派生移出相机传输协程。单线程调度器保证位图内存峰值可控，低线程优先级让
     * 相机 IO 优先；任务数单独计数，使最后一张边框完成前前台服务不会被提前停止。
     */
    private fun launchPhotoFrameExport(
        taskId: Long,
        treeUri: Uri,
        sourceUri: Uri,
        sourceName: String,
        preset: PhotoFramePreset,
        borderEnabled: Boolean,
        watermarkRequested: PhotoFrameWatermark,
        decorationRequested: Boolean = true,
        filterRequested: PhotoFilterSelection? = null,
        skipIfExisting: Boolean = false,
        failTaskOnError: Boolean = false,
    ) {
        activePhotoFrameExports.incrementAndGet()
        val job = viewModelScope.launch(photoFrameDispatcher) {
            val destinationKey = treeUri.toString()
            val outcome = try {
                val destination = photoFrameDestinations[destinationKey]
                    ?: PhotoFrameExporter.prepareDestination(
                        resolver = contentResolver,
                        treeUri = treeUri,
                    ).let { prepared ->
                        photoFrameDestinations.putIfAbsent(destinationKey, prepared) ?: prepared
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
                        filter = filterRequested,
                    )
                ) {
                    FrameExportOutcome.AlreadyExists
                } else {
                    PhotoFrameExporter.export(
                        context = getApplication(),
                        resolver = contentResolver,
                        destination = destination,
                        sourceUri = sourceUri,
                        sourceName = sourceName,
                        preset = preset,
                        watermark = effectiveWatermark,
                        borderEnabled = effectiveBorder,
                        filter = filterRequested,
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
            when (outcome) {
                is FrameExportOutcome.Saved -> {
                    log { "DERIVATIVE_SAVE: $sourceName -> ${outcome.displayName}" }
                }
                FrameExportOutcome.AlreadyExists -> {
                    log {
                        "DERIVATIVE_SKIP existing: $sourceName " +
                            "border=$borderEnabled preset=${preset.name}"
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
        job.invokeOnCompletion {
            updateTask(taskId) { task ->
                if (task.isGeneratingFrame) task.copy(isGeneratingFrame = false) else task
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

    /** 按 taskId 就地更新单个任务；ID 不存在时保持列表不变。用 update 保证跨线程原子读改写。 */
    private fun updateTask(taskId: Long, transform: (TransferTask) -> TransferTask) {
        _state.update { state ->
            state.copy(tasks = state.tasks.map { if (it.taskId == taskId) transform(it) else it })
        }
    }

    private inline fun log(message: () -> String) {
        if (BuildConfig.DEBUG) android.util.Log.d(TAG, message())
    }

    private fun getMimeType(fileName: String): String {
        return when {
            fileName.endsWith(".jpg", true) || fileName.endsWith(".jpeg", true) -> "image/jpeg"
            fileName.endsWith(".png", true) -> "image/png"
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
    fun withdrawTask(taskId: Long) {
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
            state.copy(
                tasks = state.tasks.filter {
                    it.status == TransferStatus.TRANSFERING ||
                        it.status == TransferStatus.WAITING ||
                        it.isGeneratingFrame
                }
            )
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
            state.copy(tasks = kept)
        }
        return removed
    }

    /**
     * 重试失败/取消的任务：保留入队时锁定的边框与水印配置，只创建新的任务 ID
     * 并重置运行状态。这样用户切换设置后，重试仍然得到入队时选定的派生图。
     */
    fun retryFailed(cameraProvider: () -> NikonCamera?) {
        val snapshot = _state.value
        val dirUri = snapshot.transferDirUri ?: return
        val retryIds = snapshot.tasks.filter {
            it.status == TransferStatus.FAILED || it.status == TransferStatus.CANCELLED
        }.mapTo(HashSet()) { it.taskId }
        if (retryIds.isEmpty()) return
        _state.update { state ->
            state.copy(tasks = state.tasks.map {
                if (
                    it.taskId in retryIds &&
                    (it.status == TransferStatus.FAILED || it.status == TransferStatus.CANCELLED)
                ) {
                    it.newAttempt()
                } else {
                    it
                }
            })
        }
        processQueue(dirUri, cameraProvider)
    }

    /** 同 [retryFailed]：只重置指定任务，绝不影响同一照片的其它边框任务。 */
    fun retrySingleTask(taskId: Long, cameraProvider: () -> NikonCamera?) {
        val snapshot = _state.value
        val task = snapshot.tasks.firstOrNull { it.taskId == taskId } ?: return
        if (task.status != TransferStatus.FAILED && task.status != TransferStatus.CANCELLED) return
        val dirUri = snapshot.transferDirUri ?: return
        _state.update { state ->
            state.copy(tasks = state.tasks.map {
                if (
                    it.taskId == taskId &&
                    (it.status == TransferStatus.FAILED || it.status == TransferStatus.CANCELLED)
                ) {
                    it.newAttempt()
                } else {
                    it
                }
            })
        }
        processQueue(dirUri, cameraProvider)
    }

    override fun onCleared() {
        super.onCleared()
        transferJob?.cancel()
        photoFrameDispatcher.close()
        // 兜底停止前台服务，防止 VM 销毁后通知残留。
        TransferService.stop(getApplication())
    }
}
