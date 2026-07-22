package com.ztransfer.protocol

import android.os.SystemClock
import java.net.SocketTimeoutException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * 无线遥控协议层：Live View、曝光参数读写、触摸对焦、遥控拍摄、事件轮询，
 * 外加开发者面板用的完整能力探测（runLabProbe）。语义与 libgphoto2 ptp.h/library.c 对照，
 * 已在 Z 30 (fw1.20) 真机全项验证。
 * 所有命令经 [NikonCamera.ioMutex] 串行，与传输/缩略图/心跳互斥，不碰下载热路径。
 *
 * 探测/诊断日志固定英文 + 十六进制（用于与 libgphoto2 语义比对），不做 i18n。
 */
object Lab {
    // ---- 标准操作码 ----
    const val GET_DEVICE_INFO = 0x1001
    const val GET_DEVICE_PROP_DESC = 0x1014
    const val GET_DEVICE_PROP_VALUE = 0x1015
    const val SET_DEVICE_PROP_VALUE = 0x1016

    // ---- Nikon 厂商操作码（语义来源 libgphoto2 ptp.h/library.c）----
    const val NK_START_LIVE_VIEW = 0x9201
    const val NK_END_LIVE_VIEW = 0x9202
    const val NK_GET_LIVE_VIEW_IMG = 0x9203
    const val NK_MF_DRIVE = 0x9204
    const val NK_CHANGE_AF_AREA = 0x9205
    const val NK_AF_DRIVE = 0x90C1
    const val NK_CAPTURE_REC_IN_MEDIA = 0x9207
    const val NK_CAPTURE_REC_IN_SDRAM = 0x90C0
    const val NK_GET_EVENT = 0x90C7
    const val NK_DEVICE_READY = 0x90C8
    const val NK_GET_VENDOR_PROP_CODES = 0x90CA
    const val NK_GET_VENDOR_CODES = 0x9439      // Z8/Z9 世代
    const val NK_GET_EVENT_EX = 0x941C

    const val NK_START_MOVIE_REC = 0x920A   // StartMovieRecInCard
    const val NK_END_MOVIE_REC = 0x920B     // EndMovieRec
    const val NK_CHANGE_APP_MODE = 0x9435   // ChangeApplicationMode(mode)，远程录像放行

    // ---- 事件码 ----
    const val EVT_OBJECT_ADDED = 0x4002
    const val EVT_DEVICE_PROP_CHANGED = 0x4006
    const val EVT_CAPTURE_COMPLETE = 0x400D
    const val EVT_OBJECT_ADDED_SDRAM = 0xC101
    const val EVT_NK_MOVIE_REC_INTERRUPTED = 0xC105
    const val EVT_NK_MOVIE_REC_COMPLETE = 0xC108
    const val EVT_NK_MOVIE_REC_STARTED = 0xC10A

    // ---- 响应码 ----
    const val OK = 0x2001
    const val DEVICE_BUSY = 0x2019
    const val NK_OUT_OF_FOCUS = 0xA002   // AfDrive 未能合焦
    const val NK_NOT_LIVE_VIEW = 0xA00B

    // ---- 关注的属性 ----
    const val PROP_WHITE_BALANCE = 0x5005
    const val PROP_F_NUMBER = 0x5007
    const val PROP_FOCUS_MODE = 0x500A
    const val PROP_EXPOSURE_TIME_STD = 0x500D
    const val PROP_EXPOSURE_PROGRAM = 0x500E
    const val PROP_ISO = 0x500F
    const val PROP_EXP_COMPENSATION = 0x5010
    const val PROP_NK_AUTO_ISO = 0xD054
    const val PROP_NK_SHUTTER = 0xD100
    const val PROP_NK_RECORDING_MEDIA = 0xD10B
    const val PROP_NK_LV_STATUS = 0xD1A2
    const val PROP_NK_LV_PROHIBIT = 0xD1A4
    const val PROP_NK_LV_IMAGE_SIZE = 0xD1AC
    const val PROP_NK_ISO_EX = 0xD0B4
    const val PROP_NK_ISO_CONTROL_SENSITIVITY = 0xD0B5
    const val PROP_NK_AUTO_ISO_ALT = 0xD16A
    const val PROP_NK_AF_MODE = 0xD161
    const val PROP_NK_MOV_PROHIBIT = 0xD0A4      // 录像禁止条件 bitmask，0=可录
    const val PROP_NK_LV_SELECTOR = 0xD1A6       // 照片/录像实体拨杆：0=照片 1=录像
    const val PROP_NK_APPLICATION_MODE = 0xD1F0  // Z 系远程录像放行开关（Z 30 实测需要）
    // 录像模式独立的曝光参数（与照片侧 0x5007/0xD100/0x500F/0x5010 平行的一套，
    // 拨杆在录像位时读写这组；编码与照片侧同构）
    const val PROP_NK_MOVIE_SHUTTER = 0xD1A8
    const val PROP_NK_MOVIE_F_NUMBER = 0xD1A9
    const val PROP_NK_MOVIE_ISO = 0xD1AA
    const val PROP_NK_MOVIE_EXP_COMP = 0xD1AB

    /** 探测清单：操作码 -> 可读名称（勾选表用）。 */
    val INTEREST_OPS = linkedMapOf(
        NK_START_LIVE_VIEW to "StartLiveView",
        NK_END_LIVE_VIEW to "EndLiveView",
        NK_GET_LIVE_VIEW_IMG to "GetLiveViewImg",
        0x9428 to "GetLiveViewImgEx(Z8/Z9)",
        NK_CAPTURE_REC_IN_MEDIA to "InitiateCaptureRecInMedia",
        NK_CAPTURE_REC_IN_SDRAM to "InitiateCaptureRecInSdram",
        0x90CB to "AfCaptureSDRAM",
        0x90C1 to "AfDrive",
        0x9205 to "ChangeAfArea",
        0x920C to "TerminateCapture(Bulb)",
        0x920A to "StartMovieRec",
        0x920B to "EndMovieRec",
        NK_GET_EVENT to "GetEvent",
        NK_GET_EVENT_EX to "GetEventEx",
        NK_DEVICE_READY to "DeviceReady",
        0x90C2 to "ChangeCameraMode",
        0x9435 to "ChangeApplicationMode",
        NK_GET_VENDOR_PROP_CODES to "GetVendorPropCodes",
        NK_GET_VENDOR_CODES to "GetVendorCodes(Z8/Z9)",
        GET_DEVICE_PROP_DESC to "GetDevicePropDesc",
        GET_DEVICE_PROP_VALUE to "GetDevicePropValue",
        SET_DEVICE_PROP_VALUE to "SetDevicePropValue",
        0x101B to "GetPartialObject",
    )

    val INTEREST_PROPS = linkedMapOf(
        PROP_F_NUMBER to "FNumber",
        PROP_NK_SHUTTER to "NikonShutterSpeed",
        PROP_EXPOSURE_TIME_STD to "ExposureTime(std)",
        PROP_ISO to "ISO",
        PROP_NK_AUTO_ISO to "AutoISO",
        PROP_NK_ISO_EX to "ISOEx",
        PROP_NK_ISO_CONTROL_SENSITIVITY to "ISOControlSensitivity",
        PROP_NK_AUTO_ISO_ALT to "AutoISOAlt",
        PROP_EXP_COMPENSATION to "ExpCompensation",
        PROP_EXPOSURE_PROGRAM to "ExposureProgram",
        PROP_WHITE_BALANCE to "WhiteBalance",
        PROP_FOCUS_MODE to "FocusMode",
        PROP_NK_AF_MODE to "NikonAutofocusMode",
        PROP_NK_RECORDING_MEDIA to "RecordingMedia",
        PROP_NK_LV_STATUS to "LiveViewStatus",
        PROP_NK_LV_PROHIBIT to "LiveViewProhibit",
        PROP_NK_LV_IMAGE_SIZE to "LiveViewImageSize",
        PROP_NK_LV_SELECTOR to "LiveViewSelector",
        PROP_NK_MOV_PROHIBIT to "MovRecProhibitCond",
        PROP_NK_APPLICATION_MODE to "ApplicationMode",
        PROP_NK_MOVIE_SHUTTER to "MovieShutterSpeed",
        PROP_NK_MOVIE_F_NUMBER to "MovieFNumber",
        PROP_NK_MOVIE_ISO to "MovieISO",
        PROP_NK_MOVIE_EXP_COMP to "MovieExpComp",
    )
}

private fun hex4(v: Int) = "0x%04X".format(v and 0xFFFF)
private fun hex8(v: Long) = "0x%08X".format(v)

/** 单条无 data-out 事务：发命令、收响应码+数据载荷。与正式操作共用互斥锁。 */
suspend fun NikonCamera.labCommand(code: Int, vararg params: Int): Pair<Int, ByteArray?> =
    ioMutex.withLock {
        withContext(Dispatchers.IO) {
            sendCmd(code, *params)
            recvRespWithPayload()
        }
    }

/** SetDevicePropValue：把 [raw]（属性的原始小端编码）写给相机，返回响应码。 */
suspend fun NikonCamera.labSetProp(prop: Int, raw: ByteArray): Int =
    ioMutex.withLock {
        withContext(Dispatchers.IO) {
            sendCmdWithData(Lab.SET_DEVICE_PROP_VALUE, raw, prop)
            recvRespWithPayload().first
        }
    }

// ============================ PTP 数据集解析 ============================

/** 小端游标读取器（解析 DeviceInfo/PropDesc/事件等数据集用，越界抛异常由调用方兜住）。 */
private class Cur(val d: ByteArray) {
    var p = 0
    fun u8(): Int = d[p++].toInt() and 0xFF
    fun u16(): Int {
        val v = (d[p].toInt() and 0xFF) or ((d[p + 1].toInt() and 0xFF) shl 8)
        p += 2; return v
    }
    fun u32(): Long {
        var v = 0L
        for (i in 0 until 4) v = v or ((d[p + i].toLong() and 0xFF) shl (8 * i))
        p += 4; return v
    }
    fun u64(): Long {
        var v = 0L
        for (i in 0 until 8) v = v or ((d[p + i].toLong() and 0xFF) shl (8 * i))
        p += 8; return v
    }

    /** PTP 字符串：u8 字符数（含终止 null）+ UTF-16LE。 */
    fun str(): String {
        val n = u8()
        if (n == 0) return ""
        val s = String(d, p, n * 2, Charsets.UTF_16LE).trimEnd('\u0000')
        p += n * 2
        return s
    }

    /** PTP AUINT16 数组：u32 count + count×u16。 */
    fun u16Array(): IntArray {
        val n = u32().toInt()
        return IntArray(n) { u16() }
    }

    /**
     * 按 PTP dataType 读一个值。标量返回符号处理后的 Long；字符串/数组返回 0 并跳过。
     * 返回 (raw, 是否标量)。
     */
    fun typed(dataType: Int): Pair<Long, Boolean> = when (dataType) {
        0x0001 -> u8().toByte().toLong() to true            // INT8
        0x0002 -> u8().toLong() to true                     // UINT8
        0x0003 -> u16().toShort().toLong() to true          // INT16
        0x0004 -> u16().toLong() to true                    // UINT16
        0x0005 -> u32().toInt().toLong() to true            // INT32
        0x0006 -> u32() to true                             // UINT32
        0x0007, 0x0008 -> u64() to true                     // INT64/UINT64（显示按无符号即可）
        0x0009, 0x000A -> { p += 16; 0L to false }          // INT128/UINT128
        0xFFFF -> { str(); 0L to false }                    // STR
        else -> {                                            // 数组类型 0x40xx：u32 count + 元素
            if (dataType and 0x4000 != 0) {
                val elem = dataType and 0xFF
                val size = when (elem) {
                    0x01, 0x02 -> 1; 0x03, 0x04 -> 2; 0x05, 0x06 -> 4; else -> 8
                }
                val n = u32().toInt()
                p += n * size
            }
            0L to false
        }
    }
}

data class LabDeviceInfo(
    val manufacturer: String,
    val model: String,
    val deviceVersion: String,
    val serial: String,
    val vendorExtId: Long,
    val vendorExtVersion: Int,
    val vendorExtDesc: String,
    val operations: Set<Int>,
    val events: Set<Int>,
    val props: Set<Int>,
)

private fun parseDeviceInfo(d: ByteArray): LabDeviceInfo {
    val c = Cur(d)
    c.u16()                       // StandardVersion
    val vendorExtId = c.u32()
    val vendorExtVersion = c.u16()
    val vendorExtDesc = c.str()
    c.u16()                       // FunctionalMode
    val ops = c.u16Array().toSet()
    val events = c.u16Array().toSet()
    val props = c.u16Array().toSet()
    c.u16Array()                  // CaptureFormats
    c.u16Array()                  // ImageFormats
    val manufacturer = c.str()
    val model = c.str()
    val version = c.str()
    val serial = c.str()
    return LabDeviceInfo(manufacturer, model, version, serial, vendorExtId, vendorExtVersion, vendorExtDesc, ops, events, props)
}

/** 按属性语义把原始值排成人话（快门分数、光圈 f 值、EV 等）。 */
private fun fmtVal(prop: Int, raw: Long): String = when (prop) {
    Lab.PROP_F_NUMBER, Lab.PROP_NK_MOVIE_F_NUMBER -> "f/%.1f".format(raw / 100.0)
    Lab.PROP_NK_SHUTTER, Lab.PROP_NK_MOVIE_SHUTTER -> when (raw) {
        0xFFFFFFFFL -> "Bulb"
        0xFFFFFFFEL -> "x200"
        0xFFFFFFFDL -> "Time"
        else -> {
            // 分子/分母编码，慢速档分子>1（如 300/10=30s），直接打分数不像人话，约分展示。
            val num = (raw ushr 16) and 0xFFFFL
            val den = raw and 0xFFFFL
            when {
                num == 0L || den == 0L -> "$raw"
                num == 1L -> "1/${den}s"
                num % den == 0L -> "${num / den}s"            // 300/10 → 30s
                den % num == 0L -> "1/${den / num}s"          // 2/500 → 1/250s
                else -> "%.1fs".format(num.toDouble() / den)  // 13/10 → 1.3s
            }
        }
    }
    Lab.PROP_EXPOSURE_TIME_STD -> "%.4fs".format(raw / 10000.0)
    Lab.PROP_EXP_COMPENSATION, Lab.PROP_NK_MOVIE_EXP_COMP -> "%+.1fEV".format(raw / 1000.0)
    Lab.PROP_ISO, Lab.PROP_NK_ISO_EX, Lab.PROP_NK_ISO_CONTROL_SENSITIVITY,
    Lab.PROP_NK_MOVIE_ISO -> "ISO$raw"
    Lab.PROP_NK_AUTO_ISO, Lab.PROP_NK_AUTO_ISO_ALT -> if (raw == 0L) "Off" else "On"
    Lab.PROP_EXPOSURE_PROGRAM -> when (raw) {
        1L -> "M"; 2L -> "P"; 3L -> "A"; 4L -> "S"; else -> "0x${raw.toString(16)}"
    }
    Lab.PROP_FOCUS_MODE -> when (raw) {
        1L -> "MF"
        2L -> "AF"
        3L -> "AF Macro"
        0x8010L -> "AF-S"
        0x8011L -> "AF-C"
        0x8012L -> "AF-A"
        0x8013L -> "AF-F"
        else -> "0x${raw.toString(16)}"
    }
    Lab.PROP_NK_AF_MODE -> when (raw) {
        0L -> "AF-S"
        1L -> "AF-C"
        2L -> "AF-A"
        // 3/4 会在部分机型 AF 失败后出现，并不代表用户切到了 MF。
        // 语义未确认前保留为未知值，由上层隐藏标签。
        else -> "0x${raw.toString(16)}"
    }
    else -> "$raw"
}

/** 解析 DevicePropDesc 并格式化成单段日志文本。 */
private fun parsePropDesc(prop: Int, d: ByteArray): String {
    val c = Cur(d)
    c.u16()                                     // propCode（回显）
    val dataType = c.u16()
    val rw = c.u8()                             // 0=只读 1=可写
    val (def, defScalar) = c.typed(dataType)
    val (cur, curScalar) = c.typed(dataType)
    val formFlag = c.u8()
    val form = when (formFlag) {
        1 -> {
            val (min, _) = c.typed(dataType)
            val (max, _) = c.typed(dataType)
            val (step, _) = c.typed(dataType)
            "range[${fmtVal(prop, min)}..${fmtVal(prop, max)} step $step]"
        }
        2 -> {
            val n = c.u16()
            val values = (0 until n).map { c.typed(dataType).first }
            val shown = values.take(12).joinToString(",") { fmtVal(prop, it) }
            "enum(${n})[${shown}${if (n > 12) ",…" else ""}]"
        }
        else -> "none"
    }
    val curTxt = if (curScalar) "${fmtVal(prop, cur)} (raw=$cur)" else "<non-scalar>"
    val defTxt = if (defScalar) fmtVal(prop, def) else "<non-scalar>"
    return "type=${hex4(dataType)} ${if (rw == 1) "RW" else "RO"} cur=$curTxt def=$defTxt $form"
}

/** 解析 Nikon GetEvent(0x90C7) 载荷：u16 count + count×{u16 code, u32 param}。 */
private fun parseEvents(d: ByteArray): List<Pair<Int, Long>> {
    val c = Cur(d)
    val n = c.u16()
    return (0 until n).map { c.u16() to c.u32() }
}

/** 在数据里找 JPEG SOI（FF D8 FF）偏移；找不到返回 -1。 */
private fun findJpegStart(d: ByteArray): Int {
    for (i in 0 until d.size - 2) {
        if (d[i] == 0xFF.toByte() && d[i + 1] == 0xD8.toByte() && d[i + 2] == 0xFF.toByte()) return i
    }
    return -1
}

// ============================ 正式遥控页协议支持 ============================

/** DevicePropDesc 的结构化解析结果。 */
private data class PropDescData(
    val dataType: Int,
    val writable: Boolean,
    val current: Long,
    val enumValues: List<Long>
)

private fun parsePropDescData(d: ByteArray): PropDescData {
    val c = Cur(d)
    c.u16()
    val dataType = c.u16()
    val writable = c.u8() == 1           // GetSet
    c.typed(dataType)                    // default
    val (cur, _) = c.typed(dataType)
    val formFlag = c.u8()
    val values = if (formFlag == 2) {
        val n = c.u16()
        (0 until n).map { c.typed(dataType).first }
    } else emptyList()
    return PropDescData(dataType, writable, cur, values)
}

private fun encodeScalar(dataType: Int, v: Long): ByteArray {
    val size = when (dataType) {
        0x0001, 0x0002 -> 1
        0x0003, 0x0004 -> 2
        0x0005, 0x0006 -> 4
        else -> 8
    }
    return ByteArray(size) { i -> ((v shr (8 * i)) and 0xFF).toByte() }
}

/** 一个曝光参数的完整描述。值域来自相机且随曝光模式动态变化，收到
 *  DevicePropChanged(0x4006) 事件后应重新拉取。 */
data class RcParam(
    val prop: Int,
    val dataType: Int,
    val writable: Boolean,
    val current: Long,
    val values: List<Long>
)

/** 当前镜头伺服方式。现代 Z 机优先走标准 FocusMode(0x500A)，旧 Nikon
 *  机身回退到厂商属性 0xD161；未知枚举保留原始值供日志定位，不伪造名称。 */
data class RcFocusMode(
    val label: String,
    val manual: Boolean,
    val prop: Int,
    val raw: Long
)

/** 遥控参数 UI 的紧凑读数；tile 已标明 ISO/EV，因此数值中不重复单位。 */
fun rcFormat(prop: Int, raw: Long): String = when (prop) {
    Lab.PROP_ISO, Lab.PROP_NK_ISO_EX, Lab.PROP_NK_ISO_CONTROL_SENSITIVITY,
    Lab.PROP_NK_MOVIE_ISO -> raw.toString()
    Lab.PROP_EXP_COMPENSATION, Lab.PROP_NK_MOVIE_EXP_COMP ->
        "%+.1f".format(raw / 1000.0)
    else -> fmtVal(prop, raw)
}

suspend fun NikonCamera.rcGetParam(prop: Int): RcParam? {
    val (rc, d) = labCommand(Lab.GET_DEVICE_PROP_DESC, prop)
    if (rc != Lab.OK || d == null) return null
    val desc = runCatching { parsePropDescData(d) }.getOrNull() ?: return null
    return RcParam(prop, desc.dataType, desc.writable, desc.current, desc.enumValues)
}

/** 只刷新标量属性的当前值，复用已取得的数据类型与值域，避免实时状态轮询重复拉描述。 */
suspend fun NikonCamera.rcRefreshParam(param: RcParam): RcParam? {
    val (rc, data) = labCommand(Lab.GET_DEVICE_PROP_VALUE, param.prop)
    if (rc != Lab.OK || data == null) return null
    val (current, scalar) = runCatching { Cur(data).typed(param.dataType) }.getOrNull()
        ?: return null
    return if (scalar) param.copy(current = current) else null
}

suspend fun NikonCamera.rcGetFocusMode(): RcFocusMode? {
    val candidates = intArrayOf(Lab.PROP_FOCUS_MODE, Lab.PROP_NK_AF_MODE)
    for (prop in candidates) {
        // 对焦模式标签宁缺毋滥：只接受 GetDevicePropValue 成功直读到的当前值。
        // PropDesc 兼容回退在部分机型的失败响应里会带无效默认值 1，曾被误显示成 MF。
        val (valueRc, valueData) = labCommand(Lab.GET_DEVICE_PROP_VALUE, prop)
        val raw = if (valueRc == Lab.OK && valueData != null &&
            (valueData.size == 1 || valueData.size == 2 ||
                valueData.size == 4 || valueData.size == 8)
        ) {
            valueData.indices.fold(0L) { acc, i ->
                acc or ((valueData[i].toLong() and 0xFF) shl (8 * i))
            }
        } else continue
        val label = fmtVal(prop, raw)
        // 未确认的厂商枚举不把十六进制原值当成面向用户的模式标签。
        if (label.startsWith("0x")) continue
        val result = RcFocusMode(
            label = label,
            manual = when (prop) {
                Lab.PROP_FOCUS_MODE -> raw == 1L
                Lab.PROP_NK_AF_MODE -> false
                else -> false
            },
            prop = prop,
            raw = raw
        )
        return result
    }
    return null
}

suspend fun NikonCamera.rcSetValue(param: RcParam, value: Long): Int =
    labSetProp(param.prop, encodeScalar(param.dataType, value))

/** AF 驱动后的最终结果，[polls] 是 DeviceReady 查询次数。 */
data class RcAfResult(
    val responseCode: Int,
    val polls: Int,
    val elapsedMs: Long,
    val timedOut: Boolean
)

data class RcTapFocusResult(
    val moveResponseCode: Int,
    val afResult: RcAfResult?
)

private fun NikonCamera.recvFocusResponse(deadlineMs: Long): Pair<Int, ByteArray?> {
    val remaining = deadlineMs - SystemClock.elapsedRealtime()
    if (remaining <= 0L) {
        // 调用方在进入本函数前已发出命令；即使还没有开始读，其响应也
        // 必然会迟到并污染下一事务，因此同样必须废弃连接。
        abortProtocolTransport()
        throw SocketTimeoutException("Focus response deadline exceeded")
    }
    val previousTimeout = setCommandReadTimeout(
        remaining.coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
    )
    return try {
        recvRespWithPayload()
    } catch (e: SocketTimeoutException) {
        // 超时时 PacketReader 可能已消费半个包，不能继续复用该流。
        abortProtocolTransport()
        throw e
    } finally {
        runCatching { restoreCommandReadTimeout(previousTimeout) }
    }
}

private suspend fun NikonCamera.afDriveAndWaitLocked(
    startedAt: Long,
    deadlineMs: Long
): RcAfResult {
    if (SystemClock.elapsedRealtime() >= deadlineMs) {
        return RcAfResult(Lab.DEVICE_BUSY, 0, SystemClock.elapsedRealtime() - startedAt, true)
    }
    sendCmd(Lab.NK_AF_DRIVE)
    val startRc = recvFocusResponse(deadlineMs).first
    if (startRc != Lab.OK) {
        return RcAfResult(startRc, 0, SystemClock.elapsedRealtime() - startedAt, false)
    }

    var polls = 0
    while (true) {
        if (SystemClock.elapsedRealtime() >= deadlineMs) {
            return RcAfResult(
                responseCode = Lab.DEVICE_BUSY,
                polls = polls,
                elapsedMs = SystemClock.elapsedRealtime() - startedAt,
                timedOut = true
            )
        }
        sendCmd(Lab.NK_DEVICE_READY)
        val readyRc = recvFocusResponse(deadlineMs).first
        polls++
        if (readyRc != Lab.DEVICE_BUSY) {
            return RcAfResult(
                responseCode = readyRc,
                polls = polls,
                elapsedMs = SystemClock.elapsedRealtime() - startedAt,
                timedOut = false
            )
        }
        if (SystemClock.elapsedRealtime() >= deadlineMs) {
            return RcAfResult(
                responseCode = Lab.DEVICE_BUSY,
                polls = polls,
                elapsedMs = SystemClock.elapsedRealtime() - startedAt,
                timedOut = true
            )
        }
        delay(150)
    }
}

/**
 * 按 Nikon 实机抓包时序执行一次完整自动对焦：
 *
 * 1. 只发一次 AfDrive(0x90C1)；
 * 2. 轮询 DeviceReady(0x90C8)；
 * 3. 0x2019 继续等待，0x2001 为合焦成功，0xA002 为未合焦。
 *
 * 整个序列持有 [NikonCamera.ioMutex]，防止 Live View 取帧或事件轮询插入 AF
 * 事务中间。这与抓包中对焦期间暂停取帧的行为一致。
 */
suspend fun NikonCamera.rcAfDriveAndWait(timeoutMs: Long = 6_000L): RcAfResult =
    ioMutex.withLock {
        withContext(Dispatchers.IO) {
            val startedAt = SystemClock.elapsedRealtime()
            afDriveAndWaitLocked(startedAt, startedAt + timeoutMs)
        }
    }

/** 移动 AF 区域并立即执行一次完整 AF，整套命令不被取帧打断。 */
suspend fun NikonCamera.rcFocusAt(
    x: Int,
    y: Int,
    timeoutMs: Long = 6_000L
): RcTapFocusResult = ioMutex.withLock {
    withContext(Dispatchers.IO) {
        val startedAt = SystemClock.elapsedRealtime()
        val deadlineMs = startedAt + timeoutMs
        sendCmd(Lab.NK_CHANGE_AF_AREA, x, y)
        val moveRc = recvFocusResponse(deadlineMs).first
        if (moveRc != Lab.OK) RcTapFocusResult(moveRc, null)
        else {
            // 实抓三次均为 ChangeAfArea OK 后 80–84ms 再发 AfDrive；给相机时间
            // 把新坐标应用到 AF 区域，避免驱动仍落在上一个点位。
            delay(80)
            RcTapFocusResult(moveRc, afDriveAndWaitLocked(startedAt, deadlineMs))
        }
    }
}

suspend fun NikonCamera.rcPollEvents(): List<Pair<Int, Long>> {
    val (rc, d) = labCommand(Lab.NK_GET_EVENT)
    if (rc != Lab.OK || d == null) return emptyList()
    return runCatching { parseEvents(d) }.getOrDefault(emptyList())
}

/** 发单条命令，DEVICE_BUSY 时退避重试（200ms × 5）。拍摄/录像触发类命令共用。 */
private suspend fun NikonCamera.cmdBusyRetry(code: Int, vararg params: Int): Int {
    var rc = labCommand(code, *params).first
    var tries = 0
    while (rc == Lab.DEVICE_BUSY && tries < 5) {
        delay(200)
        rc = labCommand(code, *params).first
        tries++
    }
    return rc
}

/** 触发拍摄（无 AF、存卡）。只负责发命令；完成与新照片经事件（ObjectAdded）通知。 */
suspend fun NikonCamera.rcCapture(): Int =
    cmdBusyRetry(Lab.NK_CAPTURE_REC_IN_MEDIA, -1 /*no AF*/, 0 /*card*/)

/** 设置 Live View 分辨率（1=QVGA 2=VGA 3=XGA）。必须在 LV 关闭时调用才生效。 */
suspend fun NikonCamera.rcSetLvSize(size: Int): Int =
    labSetProp(Lab.PROP_NK_LV_IMAGE_SIZE, byteArrayOf(size.toByte()))

/** 实体照片/录像拨杆位置（LiveViewSelector 0xD1A6）：false=照片 true=录像。
 *  读不到（机型无此属性/暂不可读）返回 null，调用方按"照片"处理。 */
suspend fun NikonCamera.rcGetMovieMode(): Boolean? {
    val (rc, d) = labCommand(Lab.GET_DEVICE_PROP_VALUE, Lab.PROP_NK_LV_SELECTOR)
    if (rc != Lab.OK || d == null || d.isEmpty()) return null
    return d[0].toInt() != 0
}

/** 开始录像（存卡）。忙则重试。失败时读录像禁止条件（0xD0A4 bitmask）记日志便于
 *  排查（无卡/机身菜单占用等）；成功路径不多花往返（同 labStartLiveView 的取舍）。
 *  调研提到个别 Z 机型需先设 ApplicationMode(0xD1F0)=1 才放行——【刻意不自动写】：
 *  改属性会永久改变机身状态且无恢复路径，还会在无卡等无关失败时误触发；
 *  若真机验证（清单 4A.2）失败，再按实测响应码显式支持。 */
suspend fun NikonCamera.rcStartMovie(log: (String) -> Unit = {}): Int {
    val rc = cmdBusyRetry(Lab.NK_START_MOVIE_REC)
    if (rc != Lab.OK) {
        log("!! StartMovieRec resp=${hex4(rc)}")
        val (prc, pd) = labCommand(Lab.GET_DEVICE_PROP_VALUE, Lab.PROP_NK_MOV_PROHIBIT)
        if (prc == Lab.OK && pd != null && pd.size >= 4) {
            val cond = Cur(pd).u32()
            if (cond != 0L) log("!! MovRecProhibit=${hex8(cond)}")
        }
    }
    return rc
}

/** 结束录像。忙则重试；实际停止以事件（0xC108 完成 / 0xC105 中断）为准。 */
suspend fun NikonCamera.rcEndMovie(): Int = cmdBusyRetry(Lab.NK_END_MOVIE_REC)

/** 设/清应用模式（0xD1F0）：Z 系（Z 30 实测）远程开录的放行开关。
 *  调用方负责成对使用——设 1 后在录像结束/拨杆离开录像位时清回 0，
 *  不让相机滞留在应用模式。 */
suspend fun NikonCamera.rcSetApplicationMode(on: Boolean): Int =
    labSetProp(Lab.PROP_NK_APPLICATION_MODE, byteArrayOf(if (on) 1 else 0))

/** ChangeApplicationMode（0x9435）：放行的操作码路线（属性路线不通时的备选）。 */
suspend fun NikonCamera.rcChangeApplicationMode(mode: Int): Int =
    labCommand(Lab.NK_CHANGE_APP_MODE, mode).first

/** 相机型号（DeviceInfo.Model），遥控页标题用。 */
suspend fun NikonCamera.rcModelName(): String? {
    val (rc, d) = labCommand(Lab.GET_DEVICE_INFO)
    if (rc != Lab.OK || d == null) return null
    return runCatching { parseDeviceInfo(d).model }.getOrNull()
}

// ============================ Live View ============================

/**
 * 启动 Live View：Start（忙重试）→ DeviceReady 轮询直到就绪。
 * 返回是否成功；过程写入 [log]。
 */
suspend fun NikonCamera.labStartLiveView(log: suspend (String) -> Unit): Boolean {
    // 0x2019 忙 / 0xA004 InvalidStatus（上一次 EndLiveView 后相机内部状态未落定时常见）
    // 都值得短暂重试。
    var rc = labCommand(Lab.NK_START_LIVE_VIEW).first
    var tries = 0
    while ((rc == Lab.DEVICE_BUSY || rc == 0xA004) && tries < 5) {
        delay(300)
        rc = labCommand(Lab.NK_START_LIVE_VIEW).first
        tries++
    }
    log((if (rc == Lab.OK) "" else "!! ") +
        "StartLiveView(0x9201) resp=${hex4(rc)}${if (tries > 0) " after $tries busy-retries" else ""}")
    if (rc != Lab.OK) {
        // 失败才读禁止条件用于诊断——成功路径省掉这条往返，进页更快。
        val (prc, pd) = labCommand(Lab.GET_DEVICE_PROP_VALUE, Lab.PROP_NK_LV_PROHIBIT)
        if (prc == Lab.OK && pd != null && pd.size >= 4) {
            log("!! LV prohibit condition = ${hex8(Cur(pd).u32())}")
        }
        return false
    }

    val t0 = System.currentTimeMillis()
    var ready = rc
    while (System.currentTimeMillis() - t0 < 4000) {
        ready = labCommand(Lab.NK_DEVICE_READY).first
        if (ready != Lab.DEVICE_BUSY) break
        delay(20)   // 相机通常 20-80ms 就绪，20ms 步进能少等半拍
    }
    // 就绪属正常路径不记日志（StartLiveView 那条已标记会话启动）；没等到才值得留痕。
    if (ready != Lab.OK) {
        log("!! DeviceReady(0x90C8) resp=${hex4(ready)} after ${System.currentTimeMillis() - t0}ms")
    }
    return true
}

suspend fun NikonCamera.labEndLiveView(): Int =
    runCatching { labCommand(Lab.NK_END_LIVE_VIEW).first }.getOrDefault(-1)

/**
 * 取一帧 Live View。返回 (整包数据, JPEG偏移)——不剥离头部，调用方拿偏移直接解码
 * （BitmapFactory 支持 offset），省掉热路径上每帧一次 100KB+ 的整包拷贝。
 * 相机忙返回 null（调用方稍后重试）；其它失败抛响应码异常。
 */
suspend fun NikonCamera.labGrabFrame(): Pair<ByteArray, Int>? {
    val (rc, d) = labCommand(Lab.NK_GET_LIVE_VIEW_IMG)
    if (rc == Lab.DEVICE_BUSY) return null
    if (rc != Lab.OK || d == null) throw Exception("GetLiveViewImg resp=${hex4(rc)}")
    val soi = findJpegStart(d)
    if (soi < 0) throw Exception("GetLiveViewImg: no JPEG SOI in ${d.size} bytes")
    return d to soi
}

// ============================ 一次性完整探测 ============================

/**
 * 完整探测：DeviceInfo → 操作码勾选表 → 厂商属性码 → 关键属性 desc/读 → 写回读测试
 * （写入与当前值相同的值，零副作用验证 SetDevicePropValue 通路）→ 事件轮询 → Live View
 * 试取 8 帧（经 [onFrame] 回显）→ 收尾 EndLiveView。全程只读 + 无副作用写。
 *
 * IO 异常向上抛（socket 已死，继续无意义）；协议级失败（非 OK 响应码）逐条记录后继续。
 */
suspend fun NikonCamera.runLabProbe(
    log: suspend (String) -> Unit,
    onFrame: suspend (ByteArray) -> Unit
) {
    val t0 = System.currentTimeMillis()
    log("=== ZTransfer remote-control probe ===")

    // ---- 1. DeviceInfo ----
    val (dirc, did) = labCommand(Lab.GET_DEVICE_INFO)
    var info: LabDeviceInfo? = null
    if (dirc == Lab.OK && did != null) {
        info = runCatching { parseDeviceInfo(did) }.getOrNull()
        if (info == null) log("!! DeviceInfo parse failed, ${did.size} bytes")
    } else {
        log("!! GetDeviceInfo resp=${hex4(dirc)}")
    }
    val ops = info?.operations ?: emptySet()
    // 输出保持紧凑（日志要靠剪贴板带出来）：全量操作码/事件码/属性码清单不打印，
    // 只打印总数 + 遥控关注码的命中/缺失两行。
    info?.let {
        log("Model: ${it.manufacturer} ${it.model}  fw=${it.deviceVersion}")
        log("VendorExt: id=${hex8(it.vendorExtId)} ver=${it.vendorExtVersion}")
        log("ops=${it.operations.size} events=${it.events.size} props=${it.props.size}")
        val present = Lab.INTEREST_OPS.keys.filter { op -> op in it.operations }
        val missing = Lab.INTEREST_OPS.filterKeys { op -> op !in it.operations }
        log("remote ops OK: " + present.joinToString(" ") { op -> hex4(op) })
        if (missing.isNotEmpty()) {
            log("remote ops MISSING: " +
                    missing.entries.joinToString(" ") { (op, name) -> "${hex4(op)}($name)" })
        }
    }

    // ---- 2. 厂商属性码 ----
    var vendorProps: Set<Int> = emptySet()
    if (Lab.NK_GET_VENDOR_PROP_CODES in ops) {
        val (rc, d) = labCommand(Lab.NK_GET_VENDOR_PROP_CODES)
        if (rc == Lab.OK && d != null) {
            vendorProps = runCatching { Cur(d).u16Array().toSet() }.getOrDefault(emptySet())
            log("GetVendorPropCodes(0x90CA): ${vendorProps.size} codes")
        } else log("GetVendorPropCodes(0x90CA) resp=${hex4(rc)}")
    }

    // ---- 3. Z8/Z9 世代 GetVendorCodes（0x9439）----
    if (Lab.NK_GET_VENDOR_CODES in ops) {
        for (kind in intArrayOf(0x09, 0x0D)) {   // 0x09=操作码 0x0D=属性码（ptpwebcam 用法）
            val (rc, d) = labCommand(Lab.NK_GET_VENDOR_CODES, kind)
            if (rc == Lab.OK && d != null) {
                val parsed = runCatching { Cur(d).u16Array() }.getOrNull()
                if (parsed != null) {
                    log("GetVendorCodes(0x9439, $kind) (${parsed.size}): " +
                            parsed.sorted().joinToString(" ") { v -> hex4(v) })
                } else {
                    val dump = d.take(96).joinToString("") { b -> "%02X".format(b) }
                    log("GetVendorCodes(0x9439, $kind) ${d.size}B raw: $dump")
                }
            } else log("GetVendorCodes(0x9439, $kind) resp=${hex4(rc)}")
        }
    }

    // ---- 4. 关键属性 GetDevicePropDesc ----
    log("--- device property descriptors ---")
    val advertised = (info?.props ?: emptySet()) + vendorProps
    for ((prop, name) in Lab.INTEREST_PROPS) {
        val (rc, d) = labCommand(Lab.GET_DEVICE_PROP_DESC, prop)
        val adv = if (prop in advertised) "" else " (not advertised)"
        if (rc == Lab.OK && d != null) {
            val txt = runCatching { parsePropDesc(prop, d) }
                .getOrElse { "parse failed, ${d.size}B" }
            log("${hex4(prop)} $name: $txt$adv")
        } else {
            log("${hex4(prop)} $name: resp=${hex4(rc)}$adv")
        }
    }

    // ---- 5. GetDevicePropValue 通路交叉验证（Z8 上 desc 与 value 行为可能不同）----
    val (vrc, vd) = labCommand(Lab.GET_DEVICE_PROP_VALUE, Lab.PROP_F_NUMBER)
    log("GetDevicePropValue(FNumber) resp=${hex4(vrc)} ${vd?.size ?: 0}B")

    // ---- 6. SetDevicePropValue 零副作用测试：曝光补偿原值写回 ----
    val (crc, cd) = labCommand(Lab.GET_DEVICE_PROP_VALUE, Lab.PROP_EXP_COMPENSATION)
    if (crc == Lab.OK && cd != null && cd.isNotEmpty()) {
        val src = labSetProp(Lab.PROP_EXP_COMPENSATION, cd)
        log("SetDevicePropValue(ExpComp, unchanged value) resp=${hex4(src)}" +
                if (src == Lab.OK) "  << property write path WORKS" else "")
    } else {
        log("SetDevicePropValue test skipped (read resp=${hex4(crc)})")
    }

    // ---- 7. 事件轮询 ----
    if (Lab.NK_GET_EVENT in ops) {
        val (rc, d) = labCommand(Lab.NK_GET_EVENT)
        if (rc == Lab.OK && d != null) {
            val evts = runCatching { parseEvents(d) }.getOrDefault(emptyList())
            log("GetEvent(0x90C7): ${evts.size} pending" +
                    if (evts.isEmpty()) "" else " " + evts.joinToString(" ") { (c, p) -> "${hex4(c)}(${hex8(p)})" })
        } else log("GetEvent(0x90C7) resp=${hex4(rc)}")
    }

    // ---- 8. Live View 试取帧 ----
    log("--- live view test ---")
    if (Lab.NK_START_LIVE_VIEW !in ops) log("StartLiveView not advertised - trying anyway")
    var lvOk = false
    if (labStartLiveView(log)) {
        lvOk = true
        var got = 0
        var totalMs = 0L
        var attempts = 0
        var lastTotal = 0
        var soiOff = -1
        try {
            while (got < 8 && attempts < 30) {
                attempts++
                val f0 = System.currentTimeMillis()
                val frame = labGrabFrame()
                if (frame == null) { delay(40); continue }
                val ms = System.currentTimeMillis() - f0
                val (buf, soi) = frame
                got++
                totalMs += ms
                lastTotal = buf.size
                soiOff = soi
                onFrame(buf.copyOfRange(soi, buf.size))   // 探测仅 8 帧，拷贝无所谓
            }
            // 逐帧不打印，只汇总一行（帧大小/头偏移/平均耗时足够定位问题）
            if (got > 0) log("LV: $got frames ok / $attempts polls, ~${lastTotal / 1024}KB jpeg@$soiOff, avg ${totalMs / got}ms (~%.1f fps ceiling)".format(1000f / (totalMs / got)))
        } catch (e: Exception) {
            log("!! LV frame error: ${e.message}")
        }
        log("EndLiveView(0x9202) resp=${hex4(labEndLiveView())}")
    }

    // ---- 9. 结论 ----
    log("--- verdict ---")
    log("live view:      ${if (lvOk) "YES" else "NO"}")
    log("capture opcode: ${if (Lab.NK_CAPTURE_REC_IN_MEDIA in ops || Lab.NK_CAPTURE_REC_IN_SDRAM in ops) "advertised" else "MISSING"}")
    log("event polling:  ${if (Lab.NK_GET_EVENT in ops || Lab.NK_GET_EVENT_EX in ops) "advertised" else "MISSING"}")
    log("=== probe done in ${System.currentTimeMillis() - t0}ms ===")
}

