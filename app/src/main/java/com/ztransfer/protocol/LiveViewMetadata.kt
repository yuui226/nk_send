package com.ztransfer.protocol

/**
 * 相机对当前 Live View 对焦动作的判断。它来自帧头，只用于增强显示；
 * 正式 AF 事务仍以 DeviceReady 的终态为准。
 */
enum class LiveViewFocusJudgement {
    NONE,
    NOT_FOCUSED,
    FOCUSED
}

/**
 * 已换算到 Live View 完整画面的归一化 AF 框。
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

data class LiveViewMetadata(
    val focusJudgement: LiveViewFocusJudgement,
    val selectedFocusFrame: LiveViewFocusFrame?,
    /** `StartTracking(x, y)` 与 AF 框记录共同使用的完整画面坐标系。 */
    val trackingCoordinateWidth: Int,
    val trackingCoordinateHeight: Int,
    /** `ChangeAfArea(x, y)` 使用的相机显示坐标网格；未知头型时由 UI 回退 JPEG 尺寸。 */
    val focusCoordinateWidth: Int?,
    val focusCoordinateHeight: Int?
)

/** 一帧完整 Live View 载荷；JPEG 直接从 [jpegOffset] 解码，避免热路径复制。 */
data class LiveViewPacket(
    val bytes: ByteArray,
    val jpegOffset: Int,
    val metadata: LiveViewMetadata?,
    /** 收到完整帧的单调时钟时间；用于排除 AF 完成前已排队的旧帧。 */
    val receivedAtElapsedMs: Long
)

private fun ByteArray.be16(offset: Int): Int =
    ((this[offset].toInt() and 0xFF) shl 8) or (this[offset + 1].toInt() and 0xFF)

private fun ByteArray.be32(offset: Int): Long =
    ((be16(offset).toLong() shl 16) or be16(offset + 2).toLong()) and 0xFFFFFFFFL

/**
 * 解析 Nikon GetLiveViewImageEx(0x9428) 的 512-byte Display Information Data。
 *
 * 该布局由 Z 30 / fw 1.20 的 SnapBridge 实抓确认：
 * - 大端字段；
 * - +8 为头长，+12 为 JPEG 长度；
 * - +16/+18 为完整坐标系；
 * - +28/+30 为 `ChangeAfArea` 使用的显示坐标网格；
 * - +42 为对焦判断（0 无信息、1 未合焦、2 合焦）；
 * - +44/+45 为 AF 框数量/选中索引；
 * - +48 起每框 8 字节：宽、高、中心 X、中心 Y。
 *
 * 当前未解析（跳过的）字节范围：
 * - +4 ~ +7（4 字节）：未知；
 * - +20 ~ +27（8 字节）：未知；
 * - +32 ~ +41（10 字节）：未知；
 * - +46 ~ +47（2 字节）：在 selectedIndex 与 AF 框数据之间，未解析。
 * Z8/Z9/Z6iii 等 Expeed 7 世代可能在扩展 LV 信息块中携带机身姿态（roll/pitch），
 * 尚未抓包验证——拿到真机样本后再决定是否从此处解析，届时可免去 0xD067 轮询开销。
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
        jpegOffset != 512 ||
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
        else -> return null
    }

    val frameCount = payload[44].toInt() and 0xFF
    val selectedIndex = payload[45].toInt() and 0xFF
    val focusFrameOffset = 48
    val focusFrameStride = 8
    val maxFrameCount = (jpegOffset - focusFrameOffset) / focusFrameStride
    // 主体追踪时机身可能同时保留多个候选框；此前只接受单框，导致相机选中的
    // 追踪框被丢弃，UI 一直停在最初点击点。先校验整个记录区，再只解析选中项。
    val completeFrameTable =
        frameCount in 1..maxFrameCount &&
            selectedIndex < frameCount &&
            focusFrameOffset + frameCount * focusFrameStride <= jpegOffset
    val selectedFrame = if (completeFrameTable) {
        val offset = focusFrameOffset + selectedIndex * focusFrameStride
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

        if (valid) {
            LiveViewFocusFrame(
                centerX = centerX.toFloat() / coordinateWidth,
                centerY = centerY.toFloat() / coordinateHeight,
                width = width.toFloat() / coordinateWidth,
                height = height.toFloat() / coordinateHeight
            )
        } else {
            null
        }
    } else {
        null
    }

    return LiveViewMetadata(
        focusJudgement = judgement,
        selectedFocusFrame = selectedFrame,
        trackingCoordinateWidth = coordinateWidth,
        trackingCoordinateHeight = coordinateHeight,
        focusCoordinateWidth = focusCoordinateWidth.takeIf { validFocusCoordinateGrid },
        focusCoordinateHeight = focusCoordinateHeight.takeIf { validFocusCoordinateGrid }
    )
}
