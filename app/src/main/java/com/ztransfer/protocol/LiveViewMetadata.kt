package com.ztransfer.protocol

/**
 * 相机对当前 Live View 对焦动作的判断。它来自帧头，只用于增强显示；
 * 正式 AF 事务仍以 DeviceReady 的终态为准。
 */
enum class LiveViewFocusJudgement {
    NONE,
    NOT_FOCUSED,
    FOCUSED,
    UNKNOWN
}

/**
 * 已换算到当前 Live View 可见画面的归一化 AF 框。
 *
 * [centerX]/[centerY] 与 [width]/[height] 均在 0..1 坐标系中，UI 不需要知道
 * 不同机型使用的是传感器尺寸、显示区域尺寸还是 JPEG 尺寸。
 */
data class LiveViewFocusFrame(
    val centerX: Float,
    val centerY: Float,
    val width: Float,
    val height: Float
)

/** Visible image rectangle in the camera's full coordinate space. */
data class LiveViewDisplayArea(val left: Float, val top: Float, val width: Float, val height: Float)

/** Clip to the visible image without shifting the camera-selected region. */
internal fun mapLiveViewFocusFrame(
    frame: LiveViewFocusFrame,
    area: LiveViewDisplayArea
): LiveViewFocusFrame? {
    if (area.width <= 0f || area.height <= 0f) return null
    val left = ((frame.centerX - frame.width / 2 - area.left) / area.width).coerceAtLeast(0f)
    val top = ((frame.centerY - frame.height / 2 - area.top) / area.height).coerceAtLeast(0f)
    val right = ((frame.centerX + frame.width / 2 - area.left) / area.width).coerceAtMost(1f)
    val bottom = ((frame.centerY + frame.height / 2 - area.top) / area.height).coerceAtMost(1f)
    if (right <= left || bottom <= top) return null
    return LiveViewFocusFrame((left + right) / 2, (top + bottom) / 2, right - left, bottom - top)
}

/**
 * 相机在 LiveViewObject 帧头中给出的双声道音频电平。
 *
 * 四个值都直接对应机身的 15 段电平表：0 为静音，14 为最高段。峰值由相机
 * 自己保持，UI 不需要根据手机麦克风或 JPEG 内容估算声音。
 */
data class LiveViewSoundLevels(
    val peakLeft: Int,
    val peakRight: Int,
    val currentLeft: Int,
    val currentRight: Int
) {
    companion object {
        const val MAX_SEGMENT = 14
    }
}

data class LiveViewAttitude(val roll: Float, val pitch: Float)

data class LiveViewMetadata(
    val focusJudgement: LiveViewFocusJudgement,
    val selectedFocusFrame: LiveViewFocusFrame?,
    /** `StartTracking(x, y)` 与 AF 框记录共同使用的完整画面坐标系。 */
    val trackingCoordinateWidth: Int,
    val trackingCoordinateHeight: Int,
    /** 帧头声明的 AF 框/显示网格；它不是 `ChangeAfArea(x, y)` 的命令坐标范围。 */
    val focusCoordinateWidth: Int?,
    val focusCoordinateHeight: Int?,
    /** 视频 Live View 的机内 L/R 电平；头型不支持或字段校验失败时为 null。 */
    val soundLevels: LiveViewSoundLevels?,
    val attitude: LiveViewAttitude? = null,
    val focusFrameStatus: String = "legacy",
    val focusDisplayArea: LiveViewDisplayArea? = null,
    val focusFrames: List<LiveViewFocusFrame> = listOfNotNull(selectedFocusFrame),
    val remainingVideoTimeMs: Long? = null
)

/** 一帧完整 Live View 载荷；JPEG 直接从 [jpegOffset] 解码，避免热路径复制。 */
data class LiveViewPacket(
    val bytes: ByteArray,
    val jpegOffset: Int,
    val metadata: LiveViewMetadata?,
    /** 收到完整帧的单调时钟时间；用于排除 AF 完成前已排队的旧帧。 */
    val receivedAtElapsedMs: Long,
    /** Actual operation after any protocol fallback. */
    val operation: Int = 0
)

private fun ByteArray.be16(offset: Int): Int =
    ((this[offset].toInt() and 0xFF) shl 8) or (this[offset + 1].toInt() and 0xFF)

private fun ByteArray.be32(offset: Int): Long =
    ((be16(offset).toLong() shl 16) or be16(offset + 2).toLong()) and 0xFFFFFFFFL

private const val COMPACT_LIVE_VIEW_HEADER_SIZE = 512
private const val COMPACT_SOUND_LEVELS_OFFSET = 388
private const val EXTENDED_LIVE_VIEW_HEADER_SIZE = 1024
private const val EXTENDED_SOUND_LEVELS_OFFSET = 824

/**
 * 解析 Nikon GetLiveViewImageEx(0x9428) 的 Display Information Data。
 *
 * 该布局由 Z 30 / fw 1.20 的 SnapBridge 实抓确认：
 * - 大端字段；
 * - +8 为头长，+12 为 JPEG 长度；
 * - +16/+18 为完整坐标系；
 * - +28/+30 为 AF 框/显示数据使用的网格；不能直接作为 `ChangeAfArea` 的命令坐标范围；
 * - +42 为对焦判断（0 无信息、1 未合焦、2 合焦）；
 * - +44/+45 为 AF 框数量/选中索引；
 * - +48 起每框 8 字节：宽、高、中心 X、中心 Y。
 * - 512-byte 帧头的 +388、1024-byte 扩展帧头的 +824 起，依次为 L/R 峰值
 *   和 L/R 当前电平。两种布局都是各自的绝对偏移，不能按距帧尾推断。
 *
 * 其他字段：
 * - +4 ~ +7（4 字节）：未知；
 * - +20 ~ +27：显示区域宽高与中心，按大端解析并检查完整画面边界；
 * - +32 ~ +41（10 字节）：未知；
 * - +46 ~ +47（2 字节）：在 selectedIndex 与 AF 框数据之间，未解析。
 * 512-byte v1 帧头 +404/+408 为滚转/俯仰角：Z30 V1.20 四组姿态实测确认，
 * 大端 16.16 定点环角。竖拍时 +408 为 FFFFFFFF，有效俯仰轴改为 +412。
 * 1024-byte 扩展头的姿态位置尚未验证，不套用偏移。
 *
 * 未知版本/长度一律返回 null。AF 框记录使用同一份头部声明的数量与选中索引；
 * 只有完整记录区、索引和坐标都通过边界校验时才把框位交给 UI。
 */
internal fun parseLiveViewMetadata(
    payload: ByteArray,
    jpegOffset: Int,
    operation: Int
): LiveViewMetadata? {
    if (
        operation != Lab.NK_GET_LIVE_VIEW_IMG_EX ||
        (jpegOffset != 512 && jpegOffset != 1024) ||
        payload.size < jpegOffset + 3
    ) {
        return null
    }
    // 目前只验证过 Z 30 的 Display Information Data v1。新机型若换了头版本，
    // 宁可退回应用请求点，也不能把未知字段误读成 AF 框。
    if (payload.be16(0) != 1 || payload.be16(2) != 0) return null
    if (payload.be32(8) != jpegOffset.toLong()) return null
    if (payload.be32(12) != (payload.size - jpegOffset).toLong()) return null
    if (
        payload[jpegOffset] != 0xFF.toByte() ||
        payload[jpegOffset + 1] != 0xD8.toByte() ||
        payload[jpegOffset + 2] != 0xFF.toByte()
    ) {
        return null
    }

    val coordinateWidth = payload.be16(16)
    val coordinateHeight = payload.be16(18)
    if (coordinateWidth <= 0 || coordinateHeight <= 0) return null
    val focusCoordinateWidth = payload.be16(28)
    val focusCoordinateHeight = payload.be16(30)
    val validFocusCoordinateGrid =
        focusCoordinateWidth in 1..coordinateWidth &&
            focusCoordinateHeight in 1..coordinateHeight

    val judgement = when (payload[42].toInt() and 0xFF) {
        0 -> LiveViewFocusJudgement.NONE
        1 -> LiveViewFocusJudgement.NOT_FOCUSED
        2 -> LiveViewFocusJudgement.FOCUSED
        else -> LiveViewFocusJudgement.UNKNOWN
    }

    val frameCount = payload[44].toInt() and 0xFF
    val selectedIndex = payload[45].toInt() and 0xFF
    val focusFrameOffset = 48
    val focusFrameStride = 8
    // Do not allow AF records into the recording-time/audio fields. This is a
    // conservative boundary, not a claim about the number of subjects supported.
    val frameTableEnd = if (jpegOffset == 512) 380 else 816
    val maxFrameCount = (frameTableEnd - focusFrameOffset) / focusFrameStride
    // Z30 实机确认数量对应机内多个框；逐条校验，坏记录不影响其他有效框。
    val completeFrameTable =
        frameCount in 1..maxFrameCount &&
            focusFrameOffset + frameCount * focusFrameStride <= frameTableEnd
    fun readFrame(index: Int): LiveViewFocusFrame? {
        val offset = focusFrameOffset + index * focusFrameStride
        val width = payload.be16(offset)
        val height = payload.be16(offset + 2)
        val centerX = payload.be16(offset + 4)
        val centerY = payload.be16(offset + 6)

        val valid =
            width in 1..coordinateWidth &&
                height in 1..coordinateHeight &&
                centerX in 0..coordinateWidth &&
                centerY in 0..coordinateHeight &&
                centerX * 2 >= width &&
                centerY * 2 >= height &&
                (coordinateWidth - centerX) * 2 >= width &&
                (coordinateHeight - centerY) * 2 >= height

        return if (valid) {
            LiveViewFocusFrame(
                centerX = centerX.toFloat() / coordinateWidth,
                centerY = centerY.toFloat() / coordinateHeight,
                width = width.toFloat() / coordinateWidth,
                height = height.toFloat() / coordinateHeight
            )
        } else {
            null
        }
    }

    val areaWidth = payload.be16(20)
    val areaHeight = payload.be16(22)
    val areaCenterX = payload.be16(24)
    val areaCenterY = payload.be16(26)
    val areaValid = areaWidth in 1..coordinateWidth && areaHeight in 1..coordinateHeight &&
        areaCenterX * 2 >= areaWidth && areaCenterY * 2 >= areaHeight &&
        (coordinateWidth - areaCenterX) * 2 >= areaWidth &&
        (coordinateHeight - areaCenterY) * 2 >= areaHeight
    val displayArea = if (areaValid) LiveViewDisplayArea(
        (areaCenterX - areaWidth / 2f) / coordinateWidth,
        (areaCenterY - areaHeight / 2f) / coordinateHeight,
        areaWidth.toFloat() / coordinateWidth, areaHeight.toFloat() / coordinateHeight
    ) else null
    // Zero-filled fields are used by older captures; retain their full-frame mapping.
    // Non-zero malformed geometry must never silently be treated as a full image.
    val areaAbsent = areaWidth == 0 && areaHeight == 0 && areaCenterX == 0 && areaCenterY == 0
    val mappedRecords = if (completeFrameTable) List(frameCount) { index ->
        val frame = readFrame(index)
        when {
            frame == null -> null
            displayArea != null -> mapLiveViewFocusFrame(frame, displayArea)
            areaAbsent -> frame
            else -> null
        }
    } else emptyList()
    val mappedFrame = mappedRecords.getOrNull(selectedIndex)
    val visibleFrames = mappedRecords.filterNotNull().distinct()
    val frameStatus = when {
        frameCount == 0 -> "none"
        !completeFrameTable -> "invalid-table"
        !areaValid && !areaAbsent -> "invalid-area"
        visibleFrames.isEmpty() -> "no-valid-visible-frame"
        areaAbsent -> "full-frame"
        else -> "display-area"
    }

    val soundLevels = parseLiveViewSoundLevels(payload, jpegOffset)

    return LiveViewMetadata(
        focusJudgement = judgement,
        selectedFocusFrame = mappedFrame,
        trackingCoordinateWidth = coordinateWidth,
        trackingCoordinateHeight = coordinateHeight,
        focusCoordinateWidth = focusCoordinateWidth.takeIf { validFocusCoordinateGrid },
        focusCoordinateHeight = focusCoordinateHeight.takeIf { validFocusCoordinateGrid },
        soundLevels = soundLevels,
        attitude = parseCompactLiveViewAttitude(payload, jpegOffset),
        focusFrameStatus = frameStatus,
        focusDisplayArea = displayArea,
        focusFrames = visibleFrames,
        remainingVideoTimeMs = parseLiveViewRemainingVideoTime(payload, jpegOffset)
    )
}

/**
 * 1024-byte 扩展帧头使用绝对偏移 +824；Z 30 的 512-byte 帧头经真机安静/拍手
 * 差分确认使用绝对偏移 +388。前两字节为保持时间较长的 L/R 峰值，后两字节
 * 为逐帧变化的 L/R 当前电平；响度升高时四值均可达到 14。
 *
 * 旧的 `headerSize - 200` 推断在 512-byte 头中会落到 +312 保留区并稳定读出假 0，
 * 因此必须按头型选择已验证的绝对偏移。未确认头型返回 null，不影响其他元数据。
 */
private fun parseLiveViewSoundLevels(
    payload: ByteArray,
    headerSize: Int
): LiveViewSoundLevels? {
    val soundOffset = when (headerSize) {
        COMPACT_LIVE_VIEW_HEADER_SIZE -> COMPACT_SOUND_LEVELS_OFFSET
        EXTENDED_LIVE_VIEW_HEADER_SIZE -> EXTENDED_SOUND_LEVELS_OFFSET
        else -> return null
    }
    if (payload.size < soundOffset + 4) return null

    val peakLeft = payload[soundOffset].toInt() and 0xFF
    val peakRight = payload[soundOffset + 1].toInt() and 0xFF
    val currentLeft = payload[soundOffset + 2].toInt() and 0xFF
    val currentRight = payload[soundOffset + 3].toInt() and 0xFF
    if (
        peakLeft !in 0..LiveViewSoundLevels.MAX_SEGMENT ||
        peakRight !in 0..LiveViewSoundLevels.MAX_SEGMENT ||
        currentLeft !in 0..LiveViewSoundLevels.MAX_SEGMENT ||
        currentRight !in 0..LiveViewSoundLevels.MAX_SEGMENT
    ) {
        return null
    }

    return LiveViewSoundLevels(
        peakLeft = peakLeft,
        peakRight = peakRight,
        currentLeft = currentLeft,
        currentRight = currentRight
    )
}

/** Verified 0x9428 v1 compact layout. Extended/legacy offsets are deliberately not inferred. */
internal fun parseCompactLiveViewAttitude(payload: ByteArray, headerSize: Int): LiveViewAttitude? {
    if (headerSize != 512 || payload.size < headerSize ||
        payload.be16(0) != 1 || payload.be16(2) != 0 || payload.be32(8) != 512L) return null
    val roll = payload.be32(404)
    val landscapePitch = payload.be32(408)
    // Z30 V1.20 portrait samples: +408 is explicitly unavailable (FFFFFFFF),
    // while +412 carries the active tilt axis. Do not treat arbitrary bad values as a switch.
    val rollDegrees = roll / 65536.0
    val portrait = rollDegrees in 45.0..135.0 || rollDegrees in 225.0..315.0
    val alternateAxis = landscapePitch == 0xFFFFFFFFL && portrait
    val pitch = if (alternateAxis) payload.be32(412) else landscapePitch
    // Reserved zero-filled blocks and invalid sentinels must not look like a level camera.
    if (roll == 0L && pitch == 0L) return null
    if (roll >= 360L * 65536 || pitch >= 360L * 65536) return null
    fun degrees(raw: Long): Float = (raw / 65536f).let { if (it > 180f) it - 360f else it }
    // Both inverted orientations use a 180° neutral and reversed pitch direction.
    // Reverse portrait uses +412; inverted landscape uses +408 (+412 unavailable).
    val reversePortrait = alternateAxis && rollDegrees in 225.0..315.0
    val invertedLandscape = !alternateAxis && rollDegrees in 135.0..225.0 &&
        payload.be32(412) == 0xFFFFFFFFL
    val p = if (reversePortrait || invertedLandscape) {
        180f - pitch / 65536f
    } else degrees(pitch)
    if (kotlin.math.abs(p) > 90f) return null
    return LiveViewAttitude(degrees(roll), p)
}

/** Video block, separate from the LV shutdown countdown.
 * Z30 V1.20 compact sample: +384 matches legacy 0x9203 +64 exactly (7,500,000).
 * +380 is not the remaining-time field. Recording flag remains +392, audio +388.
 * 1024-byte layout follows the darkgrade Nikon codec independently.
 */
internal fun parseLiveViewRemainingVideoTime(payload: ByteArray, headerSize: Int): Long? {
    val offset = when (headerSize) { 512 -> 384; 1024 -> 816; else -> return null }
    if (payload.size < headerSize || payload.be16(0) != 1 || payload.be16(2) != 0 ||
        payload.be32(8) != headerSize.toLong()) return null
    val recording = payload[if (headerSize == 512) 392 else 828].toInt() and 0xFF
    if (recording !in 0..1) return null
    val millis = payload.be32(offset)
    // Reserved zero-filled standby blocks do not mean the card is full.
    return millis.takeIf { it in 0L..86_400_000L && (it > 0 || recording == 1) }
}
