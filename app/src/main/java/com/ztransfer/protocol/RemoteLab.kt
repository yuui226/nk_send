package com.ztransfer.protocol

import android.os.SystemClock
import java.net.SocketTimeoutException
import java.util.zip.CRC32
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
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
    const val GET_DEVICE_PROP_DESC = 0x1014
    const val GET_DEVICE_PROP_VALUE = 0x1015
    const val SET_DEVICE_PROP_VALUE = 0x1016

    // ---- Nikon 厂商操作码（语义来源 libgphoto2 ptp.h/library.c）----
    const val NK_START_LIVE_VIEW = 0x9201
    const val NK_END_LIVE_VIEW = 0x9202
    const val NK_GET_LIVE_VIEW_IMG = 0x9203
    const val NK_GET_LIVE_VIEW_IMG_EX = 0x9428
    const val NK_MF_DRIVE = 0x9204
    const val NK_CHANGE_AF_AREA = 0x9205
    const val NK_AF_DRIVE = 0x90C1
    const val NK_START_TRACKING = 0x9424
    const val NK_END_TRACKING = 0x9425
    const val NK_CAPTURE_REC_IN_MEDIA = 0x9207
    const val NK_CAPTURE_REC_IN_SDRAM = 0x90C0
    const val NK_SET_CONTROL_MODE = 0x90C2
    const val NK_GET_EVENT = 0x90C7
    const val NK_DEVICE_READY = 0x90C8
    const val NK_GET_VENDOR_PROP_CODES = 0x90CA
    const val NK_GET_VENDOR_CODES = 0x9439      // Z8/Z9 世代
    const val NK_GET_EVENT_EX = 0x941C
    const val NK_POWER_ZOOM_BY_FOCAL_LENGTH = 0x941E
    const val NK_GET_DEVICE_PROP_VALUE_EX = 0x943B

    const val NK_START_MOVIE_REC = 0x920A   // StartMovieRecInCard
    const val NK_END_MOVIE_REC = 0x920B     // EndMovieRec
    const val NK_CHANGE_APP_MODE = 0x9435   // ChangeApplicationMode(mode)，远程录像放行

    // ---- 事件码 ----
    const val EVT_OBJECT_ADDED = 0x4002
    const val EVT_OBJECT_REMOVED = 0x4003
    const val EVT_DEVICE_PROP_CHANGED = 0x4006
    const val EVT_CAPTURE_COMPLETE = 0x400D
    const val EVT_OBJECT_ADDED_SDRAM = 0xC101
    const val EVT_NK_MOVIE_REC_INTERRUPTED = 0xC105
    const val EVT_NK_MOVIE_REC_COMPLETE = 0xC108
    const val EVT_NK_MOVIE_REC_STARTED = 0xC10A

    // ---- 响应码 ----
    const val OK = 0x2001
    const val ACCESS_DENIED = 0x200F
    const val DEVICE_BUSY = 0x2019
    const val NK_OUT_OF_FOCUS = 0xA002   // AfDrive 未能合焦
    const val NK_INVALID_STATUS = 0xA004
    const val NK_NOT_LIVE_VIEW = 0xA00B

    // ---- 关注的属性 ----
    const val PROP_BATTERY_LEVEL = 0x5001
    const val PROP_WHITE_BALANCE = 0x5005
    const val PROP_F_NUMBER = 0x5007
    const val PROP_FOCUS_MODE = 0x500A
    const val PROP_EXPOSURE_TIME_STD = 0x500D
    const val PROP_EXPOSURE_PROGRAM = 0x500E
    const val PROP_ISO = 0x500F
    const val PROP_EXP_COMPENSATION = 0x5010
    const val PROP_DIGITAL_ZOOM = 0x5016             // 标准 PTP DigitalZoom
    const val PROP_NK_EXP_COMPENSATION = 0xD058
    const val PROP_NK_AUTO_ISO = 0xD054
    const val PROP_NK_SHUTTER = 0xD100
    const val PROP_NK_RECORDING_MEDIA = 0xD10B
    const val PROP_NK_LV_STATUS = 0xD1A2
    const val PROP_NK_LV_IMAGE_ZOOM_RATIO = 0xD1A3  // Nikon 实时取景画面放大倍率
    const val PROP_NK_LV_PROHIBIT = 0xD1A4
    const val PROP_NK_LV_IMAGE_SIZE = 0xD1AC
    const val PROP_NK_LV_ZOOM_AREA = 0xD1BD         // 放大取景区域/位置（通常只读）
    const val PROP_NK_HI_RES_ZOOM = 0x1D033         // 新世代视频高解析度数字变焦（32 位扩展属性码）
    const val PROP_NK_MOVIE_AUTO_ISO = 0xD0AD
    const val PROP_NK_ISO_EX = 0xD0B4
    const val PROP_NK_ISO_CONTROL_SENSITIVITY = 0xD0B5
    const val PROP_NK_AUTO_ISO_ALT = 0xD16A
    const val PROP_NK_AF_MODE = 0xD161
    const val PROP_NK_STILL_FOCUS_METERING_MODE = 0xD05D
    const val PROP_NK_STILL_FOCUS_MODE = 0xD061
    const val PROP_NK_ANGLE_LEVEL = 0xD067       // 机身电子水平仪滚转角，只读
                                                 // libgphoto2 ptp.h: PTP_DPC_NIKON_AngleLevel
                                                 // Z 30/Z 50/Z 8/Z 9/Z 6iii 全世代共用此 DPC
    const val PROP_NK_MOV_PROHIBIT = 0xD0A4      // 录像禁止条件 bitmask，0=可录
    const val PROP_NK_LV_SELECTOR = 0xD1A6       // 照片/录像实体拨杆：0=照片 1=录像
    const val PROP_NK_APPLICATION_MODE = 0xD1F0  // 部分机型的应用模式属性入口
    // 录像模式独立的曝光参数（与照片侧 0x5007/0xD100/0x500F/0x5010 平行的一套，
    // 拨杆在录像位时读写这组；编码与照片侧同构）
    const val PROP_NK_MOVIE_SHUTTER = 0xD1A8
    const val PROP_NK_MOVIE_F_NUMBER = 0xD1A9
    const val PROP_NK_MOVIE_ISO = 0xD1AA
    const val PROP_NK_MOVIE_EXP_COMP = 0xD1AB

    /**
     * 四类“数字变焦”必须分开探测：
     * - 0xD1A3 只放大实时取景，最接近监看页 +/- 对焦辅助；
     * - 0x5016 是标准 PTP 数字变焦，可能影响相机实际输出。
     * - 0xD1BD 是取景放大区域/位置，用来判断放大后能否遥控移动观察区域；
     * - 0x1D033 是新世代 Nikon Hi-Res Zoom。它超过 16 位，必须按 0x9439
     *   的 32 位码表保留完整编号，再作为标准 PTP 属性命令的 32 位参数传入。
     *
     * 深度探测只对相机明确报告为可写且给出值域的标量做临时写入，并保证恢复原值；
     * 在没有真机日志确认前不用于正式控制。
     */
    val DIGITAL_ZOOM_PROPS = linkedMapOf(
        PROP_NK_LV_IMAGE_ZOOM_RATIO to "NikonLiveViewImageZoomRatio",
        PROP_NK_LV_ZOOM_AREA to "NikonLiveViewZoomArea",
        PROP_DIGITAL_ZOOM to "DigitalZoom(std)",
        PROP_NK_HI_RES_ZOOM to "NikonHiResZoom(ext32)",
    )

    /** 探测清单：操作码 -> 可读名称（勾选表用）。 */
    val INTEREST_OPS = linkedMapOf(
        NK_START_LIVE_VIEW to "StartLiveView",
        NK_END_LIVE_VIEW to "EndLiveView",
        NK_GET_LIVE_VIEW_IMG to "GetLiveViewImg",
        NK_GET_LIVE_VIEW_IMG_EX to "GetLiveViewImgEx",
        NK_CAPTURE_REC_IN_MEDIA to "InitiateCaptureRecInMedia",
        NK_CAPTURE_REC_IN_SDRAM to "InitiateCaptureRecInSdram",
        0x90CB to "AfCaptureSDRAM",
        0x90C1 to "AfDrive",
        0x9205 to "ChangeAfArea",
        NK_START_TRACKING to "StartTracking",
        NK_END_TRACKING to "EndTracking",
        0x920C to "TerminateCapture(Bulb)",
        0x920A to "StartMovieRec",
        0x920B to "EndMovieRec",
        NK_GET_EVENT to "GetEvent",
        NK_GET_EVENT_EX to "GetEventEx",
        NK_POWER_ZOOM_BY_FOCAL_LENGTH to "PowerZoomByFocalLength",
        NK_DEVICE_READY to "DeviceReady",
        NK_SET_CONTROL_MODE to "SetControlMode",
        0x9435 to "ChangeApplicationMode",
        NK_GET_VENDOR_PROP_CODES to "GetVendorPropCodes",
        NK_GET_VENDOR_CODES to "GetVendorCodes(Z8/Z9)",
        GET_DEVICE_PROP_DESC to "GetDevicePropDesc",
        GET_DEVICE_PROP_VALUE to "GetDevicePropValue",
        SET_DEVICE_PROP_VALUE to "SetDevicePropValue",
        0x101B to "GetPartialObject",
    )

    val INTEREST_PROPS = linkedMapOf(
        PROP_BATTERY_LEVEL to "BatteryLevel",
        PROP_F_NUMBER to "FNumber",
        PROP_NK_SHUTTER to "NikonShutterSpeed",
        PROP_EXPOSURE_TIME_STD to "ExposureTime(std)",
        PROP_ISO to "ISO",
        PROP_NK_AUTO_ISO to "AutoISO",
        PROP_NK_ISO_EX to "ISOEx",
        PROP_NK_ISO_CONTROL_SENSITIVITY to "ISOControlSensitivity",
        PROP_NK_AUTO_ISO_ALT to "AutoISOAlt",
        PROP_EXP_COMPENSATION to "ExpCompensation",
        PROP_NK_EXP_COMPENSATION to "NikonExpCompensation",
        PROP_DIGITAL_ZOOM to "DigitalZoom(std)",
        PROP_EXPOSURE_PROGRAM to "ExposureProgram",
        PROP_WHITE_BALANCE to "WhiteBalance",
        PROP_FOCUS_MODE to "FocusMode",
        PROP_NK_AF_MODE to "NikonAutofocusMode",
        PROP_NK_STILL_FOCUS_METERING_MODE to "StillFocusMeteringMode",
        PROP_NK_STILL_FOCUS_MODE to "StillFocusMode",
        PROP_NK_ANGLE_LEVEL to "AngleLevel",
        PROP_NK_RECORDING_MEDIA to "RecordingMedia",
        PROP_NK_LV_STATUS to "LiveViewStatus",
        PROP_NK_LV_IMAGE_ZOOM_RATIO to "NikonLiveViewImageZoomRatio",
        PROP_NK_LV_ZOOM_AREA to "NikonLiveViewZoomArea",
        PROP_NK_HI_RES_ZOOM to "NikonHiResZoom(ext32)",
        PROP_NK_LV_PROHIBIT to "LiveViewProhibit",
        PROP_NK_LV_IMAGE_SIZE to "LiveViewImageSize",
        PROP_NK_LV_SELECTOR to "LiveViewSelector",
        PROP_NK_MOV_PROHIBIT to "MovRecProhibitCond",
        PROP_NK_MOVIE_AUTO_ISO to "MovieISOAutoControl",
        PROP_NK_APPLICATION_MODE to "ApplicationMode",
        PROP_NK_MOVIE_SHUTTER to "MovieShutterSpeed",
        PROP_NK_MOVIE_F_NUMBER to "MovieFNumber",
        PROP_NK_MOVIE_ISO to "MovieISO",
        PROP_NK_MOVIE_EXP_COMP to "MovieExpComp",
    )
}

private fun hex4(v: Int) = "0x%04X".format(v and 0xFFFF)
private fun hex8(v: Long) = "0x%08X".format(v)
private fun hexCode(v: Int) =
    if (v in 0..0xFFFF) hex4(v) else "0x%05X".format(v)

private const val PROBE_CODES_PER_LINE = 16

/**
 * 将完整码表拆成适合界面显示/复制的稳定文本。探测日志要由用户直接回传，
 * 所以不省略未知码，也不依赖 Set 的原始顺序。
 */
internal fun formatProbeCodeLines(
    label: String,
    codes: Collection<Int>,
    names: Map<Int, String> = emptyMap(),
): List<String> {
    val sorted = codes.distinct().sorted()
    if (sorted.isEmpty()) return listOf("$label (0): <none>")
    return sorted.chunked(PROBE_CODES_PER_LINE).mapIndexed { index, chunk ->
        val from = index * PROBE_CODES_PER_LINE + 1
        val to = from + chunk.size - 1
        "$label (${sorted.size}) [$from-$to]: " + chunk.joinToString(" ") { code ->
            names[code]?.let { "${hexCode(code)}($it)" } ?: hexCode(code)
        }
    }
}

/** 完整保留相机返回的二进制，未知/新属性可在拿不到真机时离线重新解析。 */
internal fun probeHex(data: ByteArray?): String =
    if (data == null) "<none>"
    else if (data.isEmpty()) "<empty>"
    else data.joinToString(separator = "") { "%02X".format(it.toInt() and 0xFF) }

private suspend fun logProbeCodes(
    log: suspend (String) -> Unit,
    label: String,
    codes: Collection<Int>,
    names: Map<Int, String> = emptyMap(),
) {
    formatProbeCodeLines(label, codes, names).forEach { log(it) }
}

/** 单条无 data-out 事务：发命令、收响应码+数据载荷。与正式操作共用互斥锁。 */
suspend fun NikonCamera.labCommand(code: Int, vararg params: Int): Pair<Int, ByteArray?> =
    focusMutex.withLock {
        ioMutex.withLock {
            withContext(Dispatchers.IO) {
                sendCmd(code, *params)
                recvRespWithPayload()
            }
        }
    }

/** SetDevicePropValue：把 [raw]（属性的原始小端编码）写给相机，返回响应码。 */
suspend fun NikonCamera.labSetProp(prop: Int, raw: ByteArray): Int =
    focusMutex.withLock {
        ioMutex.withLock {
            withContext(Dispatchers.IO) {
                sendCmdWithData(Lab.SET_DEVICE_PROP_VALUE, raw, prop)
                recvRespWithPayload().first
            }
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

/**
 * Nikon GetVendorCodes(0x9439) 使用 u32 count + count×u32 code。
 * 先校验数量，避免损坏的载荷按虚假数量分配大数组。
 */
internal fun parseVendorCodes32(d: ByteArray): Set<Int> {
    require(d.size >= 4) { "missing u32 count" }
    val c = Cur(d)
    val count = c.u32()
    val available = (d.size - 4) / 4
    require(count <= available.toLong()) {
        "declared $count codes but payload only contains $available"
    }
    val result = LinkedHashSet<Int>(count.toInt())
    repeat(count.toInt()) { result += c.u32().toInt() }
    return result
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

internal fun parseDeviceInfo(d: ByteArray): LabDeviceInfo {
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
    Lab.PROP_EXP_COMPENSATION, Lab.PROP_NK_EXP_COMPENSATION,
    Lab.PROP_NK_MOVIE_EXP_COMP -> "%+.1fEV".format(raw / 1000.0)
    Lab.PROP_ISO, Lab.PROP_NK_ISO_EX, Lab.PROP_NK_ISO_CONTROL_SENSITIVITY,
    Lab.PROP_NK_MOVIE_ISO -> "ISO$raw"
    Lab.PROP_NK_AUTO_ISO, Lab.PROP_NK_AUTO_ISO_ALT -> if (raw == 0L) "Off" else "On"
    // 16.16 定点度数（详见 rcAngleLevelRoll 的编码说明）。
    Lab.PROP_NK_ANGLE_LEVEL -> "%.1f°".format(raw / 65536.0)
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

private data class ProbePropDescData(
    val dataType: Int,
    val writable: Boolean,
    val defaultValue: Long,
    val defaultIsScalar: Boolean,
    val current: Long,
    val currentIsScalar: Boolean,
    val formFlag: Int,
    val rangeMin: Long? = null,
    val rangeMax: Long? = null,
    val rangeStep: Long? = null,
    val enumValues: List<Long> = emptyList(),
)

/**
 * 解析标准 DevicePropDesc。即使请求参数是 Nikon 的 32 位属性编号，返回数据集里的
 * DevicePropCode 仍是标准 u16；完整编号只存在于命令参数和 0x9439 能力表中。
 */
private fun parseProbePropDescData(prop: Int, d: ByteArray): ProbePropDescData {
    val c = Cur(d)
    val echoedProp = c.u16()
    require(echoedProp == (prop and 0xFFFF)) {
        "descriptor echoed ${hex4(echoedProp)}, expected ${hex4(prop)}"
    }
    val dataType = c.u16()
    val writable = c.u8() == 1
    val (def, defScalar) = c.typed(dataType)
    val (cur, curScalar) = c.typed(dataType)
    val formFlag = c.u8()
    var rangeMin: Long? = null
    var rangeMax: Long? = null
    var rangeStep: Long? = null
    var enumValues = emptyList<Long>()
    when (formFlag) {
        1 -> {
            rangeMin = c.typed(dataType).first
            rangeMax = c.typed(dataType).first
            rangeStep = c.typed(dataType).first
        }
        2 -> {
            val n = c.u16()
            enumValues = (0 until n).map { c.typed(dataType).first }
        }
    }
    return ProbePropDescData(
        dataType = dataType,
        writable = writable,
        defaultValue = def,
        defaultIsScalar = defScalar,
        current = cur,
        currentIsScalar = curScalar,
        formFlag = formFlag,
        rangeMin = rangeMin,
        rangeMax = rangeMax,
        rangeStep = rangeStep,
        enumValues = enumValues,
    )
}

/** 解析 DevicePropDesc 并格式化成单段日志文本。 */
private fun parsePropDesc(prop: Int, d: ByteArray): String {
    val desc = parseProbePropDescData(prop, d)
    val form = when (desc.formFlag) {
        1 ->
            "range[${fmtVal(prop, desc.rangeMin ?: 0L)}.." +
                "${fmtVal(prop, desc.rangeMax ?: 0L)} step ${desc.rangeStep}]"
        2 -> {
            // 数字变焦的全部档位正是这次探测要回收的核心信息，即使超过 12 档也不截断。
            // 其他属性仍保持紧凑展示；它们的完整二进制始终另行写入 raw 字段。
            val displayLimit = if (prop in Lab.DIGITAL_ZOOM_PROPS) Int.MAX_VALUE else 12
            val shown = desc.enumValues.take(displayLimit)
                .joinToString(",") { fmtVal(prop, it) }
            val suffix = if (desc.enumValues.size > displayLimit) ",…]" else "]"
            "enum(${desc.enumValues.size})[$shown$suffix"
        }
        else -> "none"
    }
    val curTxt =
        if (desc.currentIsScalar) "${fmtVal(prop, desc.current)} (raw=${desc.current})"
        else "<non-scalar>"
    val defTxt =
        if (desc.defaultIsScalar) fmtVal(prop, desc.defaultValue)
        else "<non-scalar>"
    return "type=${hex4(desc.dataType)} ${if (desc.writable) "RW" else "RO"} " +
        "cur=$curTxt def=$defTxt $form"
}

/** 解析 Nikon GetEvent(0x90C7)：u16 count + count×{u16 code, u32 param}。 */
internal fun parseNikonEvents(d: ByteArray): List<Pair<Int, Long>> {
    require(d.size >= 2) { "missing Nikon event count" }
    val c = Cur(d)
    val n = c.u16()
    require(n <= (d.size - 2) / 6) { "truncated Nikon event payload" }
    return (0 until n).map { c.u16() to c.u32() }
}

/**
 * 解析 Nikon GetEventEx(0x941C)：u16 count + u16 reserved，随后每项为
 * u16 code + u16 parameterCount + parameterCount×u32。只向现有调用方暴露首参数。
 */
internal fun parseNikonExtendedEvents(d: ByteArray): List<Pair<Int, Long>> {
    require(d.size >= 2) { "missing Nikon extended event count" }
    val count = Cur(d).u16()
    if (count == 0) return emptyList()
    require(d.size >= 4 && count <= (d.size - 4) / 4) {
        "truncated Nikon extended event payload"
    }
    val cursor = Cur(d).apply { p = 4 }
    return buildList(count) {
        repeat(count) {
            require(cursor.p + 4 <= d.size) { "missing Nikon extended event header" }
            val code = cursor.u16()
            val parameterCount = cursor.u16()
            require(parameterCount in 0..5 && cursor.p + parameterCount * 4 <= d.size) {
                "invalid Nikon extended event parameter count"
            }
            val firstParameter = if (parameterCount > 0) cursor.u32() else 0L
            repeat((parameterCount - 1).coerceAtLeast(0)) { cursor.u32() }
            add(code to firstParameter)
        }
    }
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
    val values = when (formFlag) {
        // Nikon 的布尔属性常用 Range(0..1) 而不是 Enumeration。只把严格的
        // 二值范围展开；其他连续范围仍保持为空，避免为曝光参数制造庞大值表。
        1 -> {
            val min = c.typed(dataType).first
            val max = c.typed(dataType).first
            val step = c.typed(dataType).first
            if (min == 0L && max == 1L && step == 1L) listOf(0L, 1L) else emptyList()
        }
        2 -> {
            val n = c.u16()
            (0 until n).map { c.typed(dataType).first }
        }
        else -> emptyList()
    }
    return PropDescData(dataType, writable, cur, values)
}

private fun encodeScalar(dataType: Int, v: Long): ByteArray {
    val size = scalarSize(dataType) ?: 8
    return ByteArray(size) { i -> ((v shr (8 * i)) and 0xFF).toByte() }
}

private fun scalarSize(dataType: Int): Int? =
    when (dataType) {
        0x0001, 0x0002 -> 1
        0x0003, 0x0004 -> 2
        0x0005, 0x0006 -> 4
        0x0007, 0x0008 -> 8
        else -> null
    }

/**
 * 深度探测不暴力枚举未知整数空间：只使用相机自己给出的 enum，或 range 的端点/
 * 当前值相邻一步。最多 8 档，既能反推出写法，也避免让用户等待几十秒。
 */
private fun digitalZoomProbeValues(desc: ProbePropDescData): List<Long> {
    val candidates = when (desc.formFlag) {
        2 -> desc.enumValues
        1 -> buildList {
            desc.rangeMin?.let(::add)
            val step = desc.rangeStep
            if (step != null && step > 0L) {
                add(desc.current - step)
                add(desc.current + step)
            }
            desc.rangeMax?.let(::add)
        }.filter { value ->
            val min = desc.rangeMin
            val max = desc.rangeMax
            (min == null || value >= min) && (max == null || value <= max)
        }
        else -> emptyList()
    }
    val distinct = candidates.distinct().filter { it != desc.current }
    if (distinct.size <= 8) return distinct
    val evenlySpaced = (0 until 8).map { index ->
        distinct[index * (distinct.lastIndex) / 7]
    }
    return evenlySpaced.distinct()
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

/** 各 Nikon 世代的 Auto ISO 属性优先级；按能力探测，不按型号字符串分支。 */
internal fun rcAutoIsoCandidateProps(movieMode: Boolean): List<Int> =
    if (movieMode) {
        listOf(
            Lab.PROP_NK_MOVIE_AUTO_ISO,
            Lab.PROP_NK_AUTO_ISO_ALT,
            Lab.PROP_NK_AUTO_ISO
        )
    } else {
        listOf(Lab.PROP_NK_AUTO_ISO, Lab.PROP_NK_AUTO_ISO_ALT)
    }

/**
 * 判断属性能否作为 Auto ISO 开关。
 *
 * 部分 Nikon 机身会把 D0AD/D054/D16A 描述为可写 UINT8，却不附带 enum/range form；
 * 这仍是标准的 0/1 On/Off 属性。只对 8 位、当前值确实为 0/1 的无 form 属性放宽，
 * 写入端仍会回读确认，避免把其他厂商属性误认成开关。
 */
internal fun RcParam.rcIsBinaryToggle(): Boolean {
    if (!writable) return false
    val hasExplicitStates = values.any { it == 0L } && values.any { it != 0L }
    val isImplicitByteToggle =
        values.isEmpty() &&
            dataType in setOf(0x0001, 0x0002) &&
            current in 0L..1L
    return hasExplicitStates || isImplicitByteToggle
}

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
    Lab.PROP_EXP_COMPENSATION, Lab.PROP_NK_EXP_COMPENSATION,
    Lab.PROP_NK_MOVIE_EXP_COMP ->
        "%+.1f".format(raw / 1000.0)
    else -> fmtVal(prop, raw)
}

suspend fun NikonCamera.rcGetParam(prop: Int): RcParam? {
    val (rc, d) = labCommand(Lab.GET_DEVICE_PROP_DESC, prop)
    if (rc != Lab.OK || d == null) return null
    val desc = runCatching { parsePropDescData(d) }.getOrNull() ?: return null
    return RcParam(prop, desc.dataType, desc.writable, desc.current, desc.enumValues)
}

/**
 * 把不同 Nikon 世代对同一曝光参数使用的属性码归一到 UI 的逻辑属性。
 * UI 始终用逻辑属性作 key，[RcParam.prop] 则保留机身实际支持、实际写入的属性码。
 */
fun rcCanonicalExposureProp(prop: Int): Int = when (prop) {
    Lab.PROP_NK_EXP_COMPENSATION -> Lab.PROP_EXP_COMPENSATION
    Lab.PROP_NK_ISO_EX -> Lab.PROP_ISO
    Lab.PROP_EXPOSURE_TIME_STD -> Lab.PROP_NK_SHUTTER
    else -> prop
}

private fun compatibleExposureProps(logicalProp: Int): IntArray = when (logicalProp) {
    Lab.PROP_EXP_COMPENSATION ->
        intArrayOf(Lab.PROP_EXP_COMPENSATION, Lab.PROP_NK_EXP_COMPENSATION)
    Lab.PROP_ISO -> intArrayOf(Lab.PROP_ISO, Lab.PROP_NK_ISO_EX)
    Lab.PROP_NK_SHUTTER -> intArrayOf(Lab.PROP_NK_SHUTTER, Lab.PROP_EXPOSURE_TIME_STD)
    else -> intArrayOf(logicalProp)
}

/**
 * 按机身实际 DevicePropDesc 选择可写曝光属性。优先使用有枚举值的可写属性，
 * 兼容仅暴露标准 PTP 属性或仅暴露 Nikon 厂商属性的机型。
 */
suspend fun NikonCamera.rcGetCompatibleParam(logicalProp: Int): RcParam? {
    var readableFallback: RcParam? = null
    for (actualProp in compatibleExposureProps(logicalProp)) {
        val param = rcGetParam(actualProp) ?: continue
        if (param.writable && param.values.isNotEmpty()) return param
        if (readableFallback == null) readableFallback = param
    }
    return readableFallback
}

/** 只刷新标量属性的当前值，复用已取得的数据类型与值域，避免实时状态轮询重复拉描述。 */
suspend fun NikonCamera.rcRefreshParam(param: RcParam): RcParam? {
    val (rc, data) = labCommand(Lab.GET_DEVICE_PROP_VALUE, param.prop)
    if (rc != Lab.OK || data == null) return null
    val (current, scalar) = runCatching { Cur(data).typed(param.dataType) }.getOrNull()
        ?: return null
    return if (scalar) param.copy(current = current) else null
}

/**
 * 机身电子水平仪（Nikon AngleLevel 0xD067）的滚转角：单位度、范围 (-180,180]，0 即水平。
 * 无法解释的编码返回 null，调用方据此不画任何角度。
 *
 * 编码依据：该属性是只读 INT32，值为 16.16 定点的度数（libgphoto2 对 0xD067 固定按
 * 1/65536 缩放渲染）。libgphoto2 自带的 nikon-z7 属性 dump 可直接验算：
 * `Angle Level(0xd067):(read only) (type=0x5) 358.8' (23514322)` → 23514322/65536 = 358.8，
 * 即相机按 0..360 的环报角，358.8 就是反方向偏 1.2°、几乎水平。
 * 8/16 位类型装不下 360° 的 16.16 编码，只可能是整度数，一并容错。
 *
 * 正负方向（顺时针为正还是为负）尚未在真机核对；若实机上水平线歪的方向相反，
 * 只需在这里对结果取反即可，绘制层不必改。
 */
fun rcAngleLevelRoll(param: RcParam): Float? {
    val degrees = when (param.dataType) {
        0x0005, 0x0006 -> param.current.toDouble() / 65536.0   // INT32/UINT32：16.16 定点
        0x0001, 0x0002, 0x0003, 0x0004 -> param.current.toDouble()
        else -> return null
    }
    if (!degrees.isFinite()) return null
    var roll = degrees % 360.0
    if (roll > 180.0) roll -= 360.0
    if (roll <= -180.0) roll += 360.0
    return roll.toFloat()
}

/**
 * 读一次电子水平仪属性描述，供后续只刷标量值（[rcRefreshParam]）复用数据类型。
 * 机身不支持 0xD067（GetDevicePropDesc 直接失败）或值不是可解释的标量时返回 null。
 *
 * 支持性只认这一次实际响应，不查 0x90CA/0x9439 的广告清单：Nikon 厂商属性经常
 * 不出现在 DeviceInfo 与厂商码列表里却照样可读（见 docs/技术调研/无线遥控相机调研.md），
 * 直接问属性描述才是权威答案。
 */
suspend fun NikonCamera.rcGetAngleLevel(): RcParam? =
    rcGetParam(Lab.PROP_NK_ANGLE_LEVEL)?.takeIf { rcAngleLevelRoll(it) != null }

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

/** 写入后由机身回读得到的结果，避免把 0x2001 误当成“参数已经采用”。 */
data class RcSetResult(
    val responseCode: Int,
    val actual: RcParam?,
    val confirmed: Boolean
)

/**
 * Nikon 某些机型会在当前曝光模式或 Live View 状态下接受 SetDevicePropValue，
 * 却延迟采用甚至保持原值。写后短暂回读，并只在相机报告目标值时确认成功；
 * DeviceBusy 和“成功但未采用”各做有限重试，绝不让 UI 长期停在乐观假值上。
 */
suspend fun NikonCamera.rcSetValueVerified(param: RcParam, value: Long): RcSetResult {
    var rc = rcSetValue(param, value)
    var busyRetries = 0
    while (rc == Lab.DEVICE_BUSY && busyRetries < 2) {
        delay(120L * (busyRetries + 1))
        rc = rcSetValue(param, value)
        busyRetries++
    }
    if (rc != Lab.OK) return RcSetResult(rc, null, false)

    var actual: RcParam? = null
    suspend fun readBack(waits: LongArray): Boolean {
        for (waitMs in waits) {
            delay(waitMs)
            rcRefreshParam(param)?.let { refreshed ->
                actual = refreshed
                if (refreshed.current == value) return true
            }
        }
        return false
    }

    if (readBack(longArrayOf(40L, 90L, 160L))) {
        return RcSetResult(rc, actual, true)
    }

    // 已经能回读且仍是旧值时，给会延迟开放写入窗口的机身一次安全重发机会。
    if (actual != null) {
        delay(100)
        rc = rcSetValue(param, value)
        if (rc == Lab.OK && readBack(longArrayOf(70L, 150L))) {
            return RcSetResult(rc, actual, true)
        }
    }
    return RcSetResult(rc, actual, false)
}

/** AF 驱动后的最终结果，[polls] 是 DeviceReady 查询次数。 */
data class RcAfResult(
    val responseCode: Int,
    val polls: Int,
    val elapsedMs: Long,
    val timedOut: Boolean
)

data class RcTapFocusResult(
    val endTrackingResponseCode: Int?,
    /** null 表示直接由 StartTracking(x,y) 接受坐标，或旧追踪未能结束。 */
    val moveResponseCode: Int?,
    val trackingResponseCode: Int?,
    val trackingStarted: Boolean,
    val afResult: RcAfResult?
)

/**
 * 相机上报的标准 PTP BatteryLevel(0x5001)。该属性规定为 UINT8 0..100；
 * 值域外的数字（部分机身可能用 0xFF 表示未知）不猜测、不折算。
 */
fun rcBatteryPercentage(param: RcParam?): Int? = param
    ?.takeIf {
        it.prop == Lab.PROP_BATTERY_LEVEL &&
            it.dataType == 0x0002 &&
            it.current in 0L..100L
    }
    ?.current
    ?.toInt()

internal data class RcTapFocusStartResult(
    val moveResponseCode: Int?,
    val trackingResponseCode: Int?,
    val afStartResponseCode: Int?
)

private fun timedOutAfResult(startedAt: Long, now: Long, polls: Int = 0) = RcAfResult(
    responseCode = Lab.DEVICE_BUSY,
    polls = polls,
    elapsedMs = now - startedAt,
    timedOut = true
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

/**
 * 一条完整的对焦 PTP 事务。锁只覆盖“发送 + 收完整响应”，等待 AF 状态的间隔不占锁，
 * 让 Live View 能在相机允许时穿插取帧。
 *
 * 返回 null 表示在拿到 I/O 锁前已超过整套对焦流程的截止时间，此时没有发送命令，
 * 因而不会留下迟到响应污染下一事务。
 */
private suspend fun NikonCamera.focusCommand(
    code: Int,
    deadlineMs: Long,
    vararg params: Int
): Pair<Int, ByteArray?>? = withContext(Dispatchers.IO) {
    ioMutex.withLock {
        focusCommandLocked(code, deadlineMs, *params)
    }
}

/** 调用方必须在 I/O 调度器持有 [NikonCamera.ioMutex]，用于组成严格时序的 AF 原子段。 */
private fun NikonCamera.focusCommandLocked(
    code: Int,
    deadlineMs: Long,
    vararg params: Int
): Pair<Int, ByteArray?>? {
    if (SystemClock.elapsedRealtime() >= deadlineMs) return null
    sendCmd(code, *params)
    return recvFocusResponse(deadlineMs)
}

/**
 * 移动 AF 点并启动主体追踪。明确不支持 StartTracking 的机身才回退一次普通 AF。
 * 调用方在整个函数外持有 I/O 锁，确保 80ms 应用窗口内不会被连续的 Live View
 * 取帧插入；普通 AF 回退启动后的就绪轮询仍可释放锁。
 */
internal suspend fun runTapFocusStart(
    trackingX: Int,
    trackingY: Int,
    focusX: Int,
    focusY: Int,
    tryTracking: Boolean,
    command: suspend (code: Int, params: IntArray) -> Int?,
    pause: suspend (Long) -> Unit
): RcTapFocusStartResult {
    if (tryTracking) {
        // Z 30 实机探测确认坐标属于 StartTracking 本身：无参调用返回 0x2006，
        // StartTracking(x,y) 返回 OK，并使增强帧开始携带选中 AF 框。
        val trackingRc = command(Lab.NK_START_TRACKING, intArrayOf(trackingX, trackingY))
            ?: return RcTapFocusStartResult(null, Lab.DEVICE_BUSY, null)
        if (trackingRc == Lab.OK) {
            // StartTracking 只选中主体并显示追踪框，不会驱动镜头。让机身先采用目标，
            // 再像普通点按 AF 一样只发送一次 AfDrive；最终状态仍由 DeviceReady 判定。
            pause(80)
            return RcTapFocusStartResult(
                moveResponseCode = null,
                trackingResponseCode = trackingRc,
                afStartResponseCode = command(Lab.NK_AF_DRIVE, intArrayOf())
            )
        }
        if (trackingRc != PtpConstants.OPERATION_NOT_SUPPORTED) {
            return RcTapFocusStartResult(null, trackingRc, null)
        }
        // 只有机身明确不支持追踪操作码时才继续走普通点按 AF。InvalidStatus/Busy 等
        // 状态错误直接上报，避免擅自改变用户预期。
    }

    val trackingUnsupported = if (tryTracking) {
        PtpConstants.OPERATION_NOT_SUPPORTED
    } else {
        null
    }
    val moveRc = command(Lab.NK_CHANGE_AF_AREA, intArrayOf(focusX, focusY))
        ?: return RcTapFocusStartResult(Lab.DEVICE_BUSY, trackingUnsupported, null)
    if (moveRc != Lab.OK) {
        return RcTapFocusStartResult(moveRc, trackingUnsupported, null)
    }

    // Z 30 / SnapBridge 实抓表明 ChangeAfArea 的新坐标需要约 80ms 才被机身采用。
    pause(80)
    return RcTapFocusStartResult(
        moveResponseCode = moveRc,
        trackingResponseCode = trackingUnsupported,
        afStartResponseCode = command(Lab.NK_AF_DRIVE, intArrayOf())
    )
}

/** 调用方必须持有 focusMutex -> ioMutex；没有活动追踪时不发送冗余命令。 */
private fun NikonCamera.endSubjectTrackingLocked(deadlineMs: Long): Int? {
    if (!subjectTrackingActive) return null
    sendCmd(Lab.NK_END_TRACKING)
    val response = recvFocusResponse(deadlineMs).first
    if (
        response == Lab.OK ||
        response == PtpConstants.OPERATION_NOT_SUPPORTED ||
        response == Lab.NK_INVALID_STATUS // 机身侧已经不处于可结束的追踪状态
    ) {
        subjectTrackingActive = false
    }
    return response
}

private suspend fun runAfReadyWait(
    startedAt: Long,
    deadlineMs: Long,
    startResponseCode: Int,
    elapsedRealtime: () -> Long,
    command: suspend (Int) -> Int?,
    pause: suspend (Long) -> Unit
): RcAfResult {
    if (startResponseCode != Lab.OK) {
        return RcAfResult(startResponseCode, 0, elapsedRealtime() - startedAt, false)
    }

    var polls = 0
    while (true) {
        if (elapsedRealtime() >= deadlineMs) {
            return timedOutAfResult(startedAt, elapsedRealtime(), polls)
        }
        val readyRc = command(Lab.NK_DEVICE_READY)
            ?: return timedOutAfResult(startedAt, elapsedRealtime(), polls)
        polls++
        if (readyRc != Lab.DEVICE_BUSY) {
            return RcAfResult(
                responseCode = readyRc,
                polls = polls,
                elapsedMs = elapsedRealtime() - startedAt,
                timedOut = false
            )
        }
        if (elapsedRealtime() >= deadlineMs) {
            return timedOutAfResult(startedAt, elapsedRealtime(), polls)
        }
        pause(150)
    }
}

internal suspend fun runAfDriveAndWait(
    startedAt: Long,
    deadlineMs: Long,
    elapsedRealtime: () -> Long,
    command: suspend (Int) -> Int?,
    pause: suspend (Long) -> Unit
): RcAfResult {
    if (elapsedRealtime() >= deadlineMs) {
        return timedOutAfResult(startedAt, elapsedRealtime())
    }
    val startRc = command(Lab.NK_AF_DRIVE)
        ?: return timedOutAfResult(startedAt, elapsedRealtime())
    return runAfReadyWait(
        startedAt = startedAt,
        deadlineMs = deadlineMs,
        startResponseCode = startRc,
        elapsedRealtime = elapsedRealtime,
        command = command,
        pause = pause
    )
}

private suspend fun NikonCamera.afDriveAndWait(
    startedAt: Long,
    deadlineMs: Long
): RcAfResult = runAfDriveAndWait(
    startedAt = startedAt,
    deadlineMs = deadlineMs,
    elapsedRealtime = SystemClock::elapsedRealtime,
    command = { code -> focusCommand(code, deadlineMs)?.first },
    pause = { durationMs -> delay(durationMs) }
)

/**
 * 按 Nikon 实机抓包时序执行一次完整自动对焦：
 *
 * 1. 只发一次 AfDrive(0x90C1)；
 * 2. 轮询 DeviceReady(0x90C8)；
 * 3. 0x2019 继续等待，0x2001 为合焦成功，0xA002 为未合焦。
 *
 * [NikonCamera.focusMutex] 防止两套 AF 流程互相穿插；[NikonCamera.ioMutex] 只保护
 * 每条完整 PTP 事务，使 Live View 能在 DeviceReady 的轮询间隔内继续取帧。
 */
suspend fun NikonCamera.rcAfDriveAndWait(timeoutMs: Long = 6_000L): RcAfResult =
    focusMutex.withLock {
        val startedAt = SystemClock.elapsedRealtime()
        val deadlineMs = startedAt + timeoutMs
        val endRc = withContext(Dispatchers.IO) {
            ioMutex.withLock { endSubjectTrackingLocked(deadlineMs) }
        }
        if (endRc != null && subjectTrackingActive) {
            RcAfResult(endRc, 0, SystemClock.elapsedRealtime() - startedAt, false)
        } else {
            afDriveAndWait(startedAt, deadlineMs)
        }
    }

/** 结束当前主体追踪；未处于追踪状态时不发送多余命令。 */
suspend fun NikonCamera.rcEndSubjectTracking(timeoutMs: Long = 6_000L): Int? =
    focusMutex.withLock {
        val deadlineMs = SystemClock.elapsedRealtime() + timeoutMs
        withContext(Dispatchers.IO) {
            ioMutex.withLock { endSubjectTrackingLocked(deadlineMs) }
        }
    }

/**
 * 在点击位置启动 Nikon 主体追踪；机身明确不支持 0x9424 时才回退单次点对焦。
 * 重新点击会先结束旧追踪，避免两个追踪生命周期互相覆盖。
 */
suspend fun NikonCamera.rcFocusAt(
    trackingX: Int,
    trackingY: Int,
    focusX: Int,
    focusY: Int,
    timeoutMs: Long = 6_000L
): RcTapFocusResult = focusMutex.withLock {
    val startedAt = SystemClock.elapsedRealtime()
    val deadlineMs = startedAt + timeoutMs
    val (endTrackingRc, start) = withContext(Dispatchers.IO) {
        ioMutex.withLock {
            val endRc = endSubjectTrackingLocked(deadlineMs)
            val startResult = if (subjectTrackingActive) {
                null
            } else {
                runTapFocusStart(
                    trackingX = trackingX,
                    trackingY = trackingY,
                    focusX = focusX,
                    focusY = focusY,
                    tryTracking = subjectTrackingSupported != false,
                    command = { code, params ->
                        focusCommandLocked(code, deadlineMs, *params)?.first
                    },
                    pause = { durationMs -> delay(durationMs) }
                )
            }
            endRc to startResult
        }
    }
    if (start == null) {
        return@withLock RcTapFocusResult(
            endTrackingResponseCode = endTrackingRc,
            moveResponseCode = null,
            trackingResponseCode = null,
            trackingStarted = false,
            afResult = null
        )
    }
    when (start.trackingResponseCode) {
        Lab.OK -> {
            subjectTrackingSupported = true
            subjectTrackingActive = true
        }
        PtpConstants.OPERATION_NOT_SUPPORTED -> subjectTrackingSupported = false
    }
    val startRc = start.afStartResponseCode
    suspend fun waitForStartedAf(): RcAfResult = if (startRc == null) {
        timedOutAfResult(startedAt, SystemClock.elapsedRealtime())
    } else {
        runAfReadyWait(
            startedAt = startedAt,
            deadlineMs = deadlineMs,
            startResponseCode = startRc,
            elapsedRealtime = SystemClock::elapsedRealtime,
            command = { code -> focusCommand(code, deadlineMs)?.first },
            pause = { durationMs -> delay(durationMs) }
        )
    }
    if (start.trackingResponseCode == Lab.OK) {
        RcTapFocusResult(
            endTrackingResponseCode = endTrackingRc,
            moveResponseCode = start.moveResponseCode,
            trackingResponseCode = start.trackingResponseCode,
            trackingStarted = true,
            afResult = waitForStartedAf()
        )
    } else if (start.moveResponseCode != null && start.moveResponseCode != Lab.OK) {
        RcTapFocusResult(
            endTrackingResponseCode = endTrackingRc,
            moveResponseCode = start.moveResponseCode,
            trackingResponseCode = start.trackingResponseCode,
            trackingStarted = false,
            afResult = null
        )
    } else if (startRc == null) {
        RcTapFocusResult(
            endTrackingResponseCode = endTrackingRc,
            moveResponseCode = start.moveResponseCode,
            trackingResponseCode = start.trackingResponseCode,
            trackingStarted = false,
            afResult = if (
                start.trackingResponseCode == null ||
                start.trackingResponseCode == PtpConstants.OPERATION_NOT_SUPPORTED
            ) {
                timedOutAfResult(startedAt, SystemClock.elapsedRealtime())
            } else {
                null
            }
        )
    } else {
        RcTapFocusResult(
            endTrackingResponseCode = endTrackingRc,
            moveResponseCode = start.moveResponseCode,
            trackingResponseCode = start.trackingResponseCode,
            trackingStarted = false,
            afResult = waitForStartedAf()
        )
    }
}

suspend fun NikonCamera.rcPollEvents(): List<Pair<Int, Long>> {
    // STA 初始化已经实际验证过 GetEventEx；只在该会话使用新格式。AP/USB 继续保持
    // 原来的 GetEvent 路径，避免把一台相机的能力假设扩散到其它连接模式。
    if (staAlbumAccessValidated) {
        val (extendedResponse, extendedData) = labCommand(Lab.NK_GET_EVENT_EX)
        if (extendedResponse == Lab.OK) {
            return extendedData?.let { data ->
                runCatching { parseNikonExtendedEvents(data) }.getOrDefault(emptyList())
            }.orEmpty()
        }
        if (extendedResponse != PtpConstants.OPERATION_NOT_SUPPORTED) return emptyList()
    }

    val (response, data) = labCommand(Lab.NK_GET_EVENT)
    if (response != Lab.OK || data == null) return emptyList()
    return runCatching { parseNikonEvents(data) }.getOrDefault(emptyList())
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

internal data class RcMovieStartResult(
    val responseCode: Int,
    val prohibitCondition: Long?,
    val prohibitExtendedResponse: Int? = null,
    val applicationModeResponse: Int? = null,
    val applicationModePropertyResponse: Int? = null,
    val startCommandResponse: Int? = responseCode,
)

internal fun RcMovieStartResult.diagnosticSummary(): String = buildString {
    append("result=").append(hex4(responseCode))
    append(" startOp=")
    append(startCommandResponse?.let(::hex4) ?: "not-sent")
    prohibitCondition?.let { append(" prohibit=").append(hex8(it)) }
    prohibitExtendedResponse?.let { append(" preEx=").append(hex4(it)) }
    applicationModeResponse?.let { append(" appOp=").append(hex4(it)) }
    applicationModePropertyResponse?.let { append(" appProp=").append(hex4(it)) }
}

private const val MOVIE_PROHIBIT_NO_CARD = 1L shl 0
private const val MOVIE_PROHIBIT_CARD_ERROR = 1L shl 1
private const val MOVIE_PROHIBIT_CARD_UNFORMATTED = 1L shl 2
private const val MOVIE_PROHIBIT_CARD_FULL = 1L shl 3
private const val MOVIE_PROHIBIT_BUFFER_PENDING = 1L shl 9
private const val MOVIE_PROHIBIT_ALREADY_RECORDING = 1L shl 10
private const val MOVIE_PROHIBIT_CARD_PROTECTED = 1L shl 11
private const val MOVIE_PROHIBIT_ENLARGED_LIVE_VIEW = 1L shl 12
private const val MOVIE_PROHIBIT_NOT_APPLICATION_MODE = 1L shl 14
private const val MOVIE_PROHIBIT_STORAGE_MASK =
    MOVIE_PROHIBIT_NO_CARD or
        MOVIE_PROHIBIT_CARD_ERROR or
        MOVIE_PROHIBIT_CARD_UNFORMATTED or
        MOVIE_PROHIBIT_CARD_FULL or
        MOVIE_PROHIBIT_CARD_PROTECTED
private const val MOVIE_PROHIBIT_RESTARTABLE_MASK =
    MOVIE_PROHIBIT_ENLARGED_LIVE_VIEW or MOVIE_PROHIBIT_NOT_APPLICATION_MODE

internal fun movieProhibitIndicatesRecording(prohibitCondition: Long?): Boolean =
    prohibitCondition?.let { it and MOVIE_PROHIBIT_ALREADY_RECORDING != 0L } == true

internal fun movieProhibitRequiresApplicationMode(prohibitCondition: Long?): Boolean =
    prohibitCondition?.let { it and MOVIE_PROHIBIT_NOT_APPLICATION_MODE != 0L } == true

internal fun shouldFallbackToApplicationModeProperty(applicationModeResponse: Int): Boolean =
    applicationModeResponse == PtpConstants.OPERATION_NOT_SUPPORTED

/**
 * 开录失败后是否值得在已进入应用模式的前提下重建一次 Live View 再试。
 * 存储卡、写缓冲和已在录像不会被重启掩盖；有明确禁止位时只接受 LV/应用模式
 * 两类可恢复状态。无禁止信息时，仅 InvalidStatus/持续 Busy 允许一次恢复。
 */
internal fun movieStartNeedsLiveViewRestart(
    responseCode: Int,
    prohibitCondition: Long?
): Boolean {
    if (responseCode == Lab.OK) return false
    if (prohibitCondition != null && prohibitCondition and MOVIE_PROHIBIT_STORAGE_MASK != 0L) {
        return false
    }
    if (prohibitCondition != null &&
        prohibitCondition and
        (MOVIE_PROHIBIT_BUFFER_PENDING or MOVIE_PROHIBIT_ALREADY_RECORDING) != 0L
    ) {
        return false
    }
    if (prohibitCondition != null && prohibitCondition != 0L) {
        return prohibitCondition and MOVIE_PROHIBIT_RESTARTABLE_MASK != 0L
    }
    return responseCode == 0xA004 || responseCode == Lab.DEVICE_BUSY
}

/** 开始录像（存卡）。忙则重试；失败时一并返回录像禁止条件供上层决定是否重建 LV。 */
internal suspend fun NikonCamera.rcStartMovieDetailed(
    log: (String) -> Unit = {}
): RcMovieStartResult {
    val rc = cmdBusyRetry(Lab.NK_START_MOVIE_REC)
    var prohibitCondition: Long? = null
    if (rc != Lab.OK) {
        log("!! StartMovieRec resp=${hex4(rc)}")
        val (prc, pd) = labCommand(Lab.GET_DEVICE_PROP_VALUE, Lab.PROP_NK_MOV_PROHIBIT)
        if (prc == Lab.OK && pd != null && pd.size >= 4) {
            val cond = Cur(pd).u32()
            prohibitCondition = cond
            if (cond != 0L) log("!! MovRecProhibit=${hex8(cond)}")
        }
    }
    return RcMovieStartResult(rc, prohibitCondition)
}

/** 执行 USB 开录序列；调用方必须已持有 ioMutex 并处于 I/O 调度器。 */
private fun NikonCamera.prepareAndStartMovieLocked(): RcMovieStartResult {
    fun command(code: Int, vararg params: Int): Pair<Int, ByteArray?> {
        sendCmd(code, *params)
        return recvRespWithPayload()
    }

    fun setProperty(prop: Int, raw: ByteArray): Int {
        sendCmdWithData(Lab.SET_DEVICE_PROP_VALUE, raw, prop)
        return recvRespWithPayload().first
    }

    fun readMovieProhibit(): Long? =
        command(
            Lab.GET_DEVICE_PROP_VALUE,
            Lab.PROP_NK_MOV_PROHIBIT
        ).let { (rc, data) ->
            if (rc == Lab.OK && data != null && data.size >= 4) Cur(data).u32() else null
        }

    val prohibitExtendedRc = command(
        Lab.NK_GET_DEVICE_PROP_VALUE_EX,
        Lab.PROP_NK_MOV_PROHIBIT
    ).first
    val preflightProhibit = readMovieProhibit()
    val applicationModeRequired =
        movieProhibitRequiresApplicationMode(preflightProhibit)

    var appOpRc: Int? = null
    var appPropRc: Int? = null
    if (applicationModeRequired &&
        !remoteMovieApplicationOpSet &&
        !remoteMovieApplicationPropSet
    ) {
        val rc = command(Lab.NK_CHANGE_APP_MODE, 1).first
        appOpRc = rc
        if (rc == Lab.OK) remoteMovieApplicationOpSet = true

        // 新世代机型优先沿用已经验证的 0x9435 路径；只有相机明确表示不支持
        // 该操作码时，才回退到旧/另一世代使用的 ApplicationMode 属性入口。
        if (shouldFallbackToApplicationModeProperty(rc)) {
            val propRc = setProperty(
                Lab.PROP_NK_APPLICATION_MODE,
                byteArrayOf(1)
            )
            appPropRc = propRc
            if (propRc == Lab.OK) {
                remoteMovieApplicationPropSet = true
                // 读取一次切换后的真实禁止条件，既让相机完成属性应用，也为失败
                // 诊断保留最新状态；是否发送开录以属性写入成功为准。
                readMovieProhibit()
            }
        }
    }

    val applicationModeReady =
        !applicationModeRequired ||
            remoteMovieApplicationOpSet ||
            remoteMovieApplicationPropSet
    val startCommandRc =
        if (applicationModeReady) command(Lab.NK_START_MOVIE_REC).first else null
    val resultRc =
        startCommandRc ?: appPropRc ?: appOpRc ?: Lab.ACCESS_DENIED

    var prohibitCondition: Long? =
        if (resultRc != Lab.OK) preflightProhibit else null
    if (resultRc != Lab.OK) {
        readMovieProhibit()?.let { prohibitCondition = it }
    }

    return RcMovieStartResult(
        responseCode = resultRc,
        prohibitCondition = prohibitCondition,
        prohibitExtendedResponse = prohibitExtendedRc,
        applicationModeResponse = appOpRc,
        applicationModePropertyResponse = appPropRc,
        startCommandResponse = startCommandRc,
    )
}

/**
 * USB 远控会话内的开录原子序列。禁止条件读取、应用模式和 0x920A 共用一次
 * [NikonCamera.ioMutex]，事件轮询与取帧不能插入中途看到半切换状态或把应用模式清回去。
 * Live View 与 PTP 会话始终保持，不在这里发送 EndLiveView。
 */
internal suspend fun NikonCamera.rcPrepareAndStartMovieDetailed(
    log: (String) -> Unit = {}
): RcMovieStartResult {
    val result = focusMutex.withLock {
        ioMutex.withLock {
            withContext(Dispatchers.IO) { prepareAndStartMovieLocked() }
        }
    }
    log("Movie prepare ${result.diagnosticSummary()}")
    return result
}

/** 结束录像。忙则重试；实际停止以事件（0xC108 完成 / 0xC105 中断）为准。 */
suspend fun NikonCamera.rcEndMovie(): Int = cmdBusyRetry(Lab.NK_END_MOVIE_REC)

/**
 * 尼康完整远控模式。USB 开录前设 1，停录回普通待机时清 0；模式切换成功后，
 * 录制期间的 Live View、参数控制和录像命令始终复用同一个 PTP 会话。
 */
suspend fun NikonCamera.rcSetControlMode(enabled: Boolean): Int {
    if (enabled == remoteControlModeSet) return Lab.OK
    val rc = cmdBusyRetry(Lab.NK_SET_CONTROL_MODE, if (enabled) 1 else 0)
    if (rc != Lab.OK) return rc
    remoteControlModeSet = enabled
    return Lab.OK
}

/** 部分 Nikon 机型通过 0xD1F0 设/清应用模式；不支持该属性的机型改走 0x9435。 */
suspend fun NikonCamera.rcSetApplicationMode(on: Boolean): Int =
    labSetProp(Lab.PROP_NK_APPLICATION_MODE, byteArrayOf(if (on) 1 else 0))

/** ChangeApplicationMode（0x9435）：放行的操作码路线（属性路线不通时的备选）。 */
suspend fun NikonCamera.rcChangeApplicationMode(mode: Int): Int =
    labCommand(Lab.NK_CHANGE_APP_MODE, mode).first

/** 相机型号（DeviceInfo.Model），遥控页标题用。 */
suspend fun NikonCamera.rcModelName(): String? = deviceModel

// ============================ Live View ============================

/** 竞品 Z30 USB 实抓：DeviceReady 后约 733ms 才开始第一笔取帧。 */
internal const val USB_LIVE_VIEW_WARMUP_MS = 750L

internal fun liveViewWarmupRemainingMs(
    connectionType: CameraConnectionType,
    readyAtElapsedMs: Long,
    nowElapsedMs: Long
): Long {
    if (connectionType != CameraConnectionType.USB || readyAtElapsedMs <= 0L) return 0L
    return (readyAtElapsedMs + USB_LIVE_VIEW_WARMUP_MS - nowElapsedMs).coerceAtLeast(0L)
}

/** 复用连接阶段缓存的 DeviceInfo 取帧能力，监看启动时不再重复查询。 */
private suspend fun NikonCamera.resolveLiveViewImageOperation() {
    if (liveViewImageOperation != null) return
    val supportsEnhanced = cachedDeviceInfo?.operations
        ?.contains(Lab.NK_GET_LIVE_VIEW_IMG_EX) == true
    liveViewImageOperation = if (supportsEnhanced) {
        Lab.NK_GET_LIVE_VIEW_IMG_EX
    } else {
        Lab.NK_GET_LIVE_VIEW_IMG
    }
}

/**
 * 启动 Live View：Start（忙重试）→ DeviceReady 轮询直到就绪。
 * 返回是否成功；过程写入 [log]。
 */
suspend fun NikonCamera.labStartLiveView(log: suspend (String) -> Unit): Boolean {
    liveViewReadyAtElapsedMs = 0L
    resolveLiveViewImageOperation()
    val frameOperation = liveViewImageOperation ?: Lab.NK_GET_LIVE_VIEW_IMG
    log("LiveView frames: ${Lab.INTEREST_OPS[frameOperation] ?: hex4(frameOperation)}")
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
    liveViewReadyAtElapsedMs = SystemClock.elapsedRealtime()
    return true
}

suspend fun NikonCamera.labEndLiveView(): Int {
    val rc = focusMutex.withLock {
        ioMutex.withLock {
            withContext(Dispatchers.IO) {
                // EndLiveView 会隐式终止画面，但不能依赖它替我们闭合追踪会话；否则下次
                // 开 LV 时机身仍可能保留旧目标。错误响应不阻止继续关 LV；但若一次事务
                // 没收完整响应，流边界已不可信，必须中止连接，不能再发下一条命令误读迟到包。
                val deadlineMs = SystemClock.elapsedRealtime() + 6_000L
                try {
                    endSubjectTrackingLocked(deadlineMs)
                    subjectTrackingActive = false
                    focusCommandLocked(Lab.NK_END_LIVE_VIEW, deadlineMs)?.first ?: -1
                } catch (e: CancellationException) {
                    throw e
                } catch (_: Exception) {
                    subjectTrackingActive = false
                    abortProtocolTransport()
                    -1
                }
            }
        }
    }
    liveViewReadyAtElapsedMs = 0L
    return rc
}

/**
 * 取一帧 Live View。首次调用从 DeviceInfo 选择机身广告的增强取帧 0x9428；明确不支持时
 * 立即回退 0x9203，其它异常连续两次才回退。整包不剥离头部，BitmapFactory 直接从
 * JPEG 偏移解码，省掉热路径上每帧一次 100KB+ 的复制。
 * 相机忙返回 null（调用方稍后重试）；其它失败抛响应码异常。
 */
suspend fun NikonCamera.labGrabFrame(): LiveViewPacket? =
    ioMutex.withLock {
        withContext(Dispatchers.IO) {
            if (liveViewImageOperation == null) {
                // 正常路径已在 labStartLiveView 前解析；仅为直接调用 labGrabFrame 的
                // 诊断代码兜底，不在 LV 运行中补发 GetDeviceInfo。
                liveViewImageOperation = Lab.NK_GET_LIVE_VIEW_IMG
            }

            fun receive(operation: Int): Pair<Int, ByteArray?> {
                sendCmd(operation)
                return recvRespWithPayload()
            }

            var operation = liveViewImageOperation ?: Lab.NK_GET_LIVE_VIEW_IMG
            var (rc, data) = receive(operation)
            var soi = data?.let(::findJpegStart) ?: -1
            val enhancedFailure =
                operation == Lab.NK_GET_LIVE_VIEW_IMG_EX &&
                (
                    (rc != Lab.OK && rc != Lab.DEVICE_BUSY && rc != Lab.NK_NOT_LIVE_VIEW) ||
                        (rc == Lab.OK && soi < 0)
                    )
            if (operation == Lab.NK_GET_LIVE_VIEW_IMG_EX && rc == Lab.OK && soi >= 0) {
                liveViewEnhancedFailureCount = 0
            } else if (enhancedFailure) {
                liveViewEnhancedFailureCount = if (rc == PtpConstants.OPERATION_NOT_SUPPORTED) {
                    2
                } else {
                    liveViewEnhancedFailureCount + 1
                }
            }
            if (enhancedFailure && liveViewEnhancedFailureCount >= 2) {
                // 明确不支持立即降级；其它错误（包括偶发空/坏首帧）连续两次才降级，
                // 避免支持增强帧的机型因一次传输抖动永久丢失 AF 元数据。
                operation = Lab.NK_GET_LIVE_VIEW_IMG
                liveViewImageOperation = operation
                liveViewEnhancedFailureCount = 0
                val fallback = receive(operation)
                rc = fallback.first
                data = fallback.second
                soi = data?.let(::findJpegStart) ?: -1
            }

            if (rc == Lab.DEVICE_BUSY) return@withContext null
            if (rc != Lab.OK || data == null) {
                throw Exception("${Lab.INTEREST_OPS[operation] ?: hex4(operation)} resp=${hex4(rc)}")
            }
            if (soi < 0) throw Exception("GetLiveViewImg: no JPEG SOI in ${data.size} bytes")
            LiveViewPacket(
                bytes = data,
                jpegOffset = soi,
                metadata = parseLiveViewMetadata(data, soi, operation),
                receivedAtElapsedMs = SystemClock.elapsedRealtime()
            )
        }
    }

internal fun trackingMotionDetected(frames: List<LiveViewFocusFrame>): Boolean {
    if (frames.size < 3) return false
    val xRange = frames.maxOf { it.centerX } - frames.minOf { it.centerX }
    val yRange = frames.maxOf { it.centerY } - frames.minOf { it.centerY }
    // 小于约 1.5% 画幅的变化可能只是机身框坐标取整/轻微抖动，不能作为追踪成立证据。
    return xRange >= 0.015f || yRange >= 0.015f
}

private data class TrackingProbeCapture(
    val packets: List<LiveViewPacket>,
    val selectedFrames: List<LiveViewFocusFrame>
) {
    val motionConfirmed: Boolean get() = trackingMotionDetected(selectedFrames)
}

private data class TrackingProbeVariantResult(
    val name: String,
    val commands: List<String>,
    val capture: TrackingProbeCapture
)

private fun trackingHeaderDiff(
    baseline: ByteArray?,
    packets: List<LiveViewPacket>
): String {
    if (baseline == null || packets.isEmpty()) return "<unavailable>"
    val headerSize = minOf(baseline.size, packets.minOf { it.jpegOffset })
    val changes = buildList {
        for (offset in 0 until headerSize) {
            val before = baseline[offset].toInt() and 0xFF
            val after = packets.map { it.bytes[offset].toInt() and 0xFF }.toSet()
            if (after.size != 1 || before !in after) {
                add(
                    "+$offset:%02X>%s".format(
                        before,
                        after.take(6).joinToString("/") { "%02X".format(it) } +
                            if (after.size > 6) "/..." else ""
                    )
                )
            }
        }
    }
    if (changes.isEmpty()) return "<none>"
    return changes.take(80).joinToString(" ") +
        if (changes.size > 80) " ... (${changes.size} offsets total)" else ""
}

/**
 * Read the focus-mode context before live view starts, keeping the timed tracking section limited
 * to live-view frames and tracking commands.
 */
private suspend fun NikonCamera.logTrackingFocusProperties(
    log: suspend (String) -> Unit
) {
    suspend fun read(prop: Int, name: String) {
        val (descRc, desc) = labCommand(Lab.GET_DEVICE_PROP_DESC, prop)
        val (valueRc, value) = labCommand(Lab.GET_DEVICE_PROP_VALUE, prop)
        val parsedDesc = if (descRc == Lab.OK && desc != null) {
            runCatching { parsePropDesc(prop, desc) }.getOrElse { "parse-failed:${it.message}" }
        } else {
            "unavailable"
        }
        log(
            "TRACKING PROP ${hex4(prop)} $name desc=${hex4(descRc)} $parsedDesc " +
                "value=${hex4(valueRc)} raw=${probeHex(value)}"
        )
    }

    read(Lab.PROP_NK_STILL_FOCUS_METERING_MODE, "StillFocusMeteringMode")
    read(Lab.PROP_NK_STILL_FOCUS_MODE, "StillFocusMode")
    read(Lab.PROP_FOCUS_MODE, "FocusMode(std)")
}

/**
 * 完整探测中的主体追踪专检。这里故意尝试几种参数/顺序组合，但只使用机身自己
 * 广告的 StartTracking/EndTracking/ChangeAfArea/AfDrive。StartTracking 使用增强帧
 * +16/+18 的完整坐标系，ChangeAfArea 使用 +28/+30 的 AF 网格。仅在 StartTracking
 * 明确成功后发送 EndTracking，避免无意义的状态命令；
 * finally 只清理已经开始的追踪状态。每条协议事务自行获取 focusMutex，外层不得重复持锁。
 *
 * 判定标准不是响应码：至少三帧带相机 AF 框，且框中心跨帧移动超过 1.5% 画幅，
 * 才标记 CAMERA_FRAME_MOTION_CONFIRMED。用户应在这段探测期间缓慢移动中央主体。
 */
private suspend fun NikonCamera.runSubjectTrackingProbe(
    advertisedOps: Set<Int>,
    log: suspend (String) -> Unit,
    onFrame: suspend (ByteArray) -> Unit
): List<TrackingProbeVariantResult> {
    log("--- subject tracking controlled probe ---")
    log("ACTION: keep a textured subject near the center and move it slowly until this section ends.")
    log("SUCCESS RULE: an OK response alone is not success; camera AF-frame motion must be observed.")

    val required = setOf(Lab.NK_CHANGE_AF_AREA, Lab.NK_START_TRACKING, Lab.NK_END_TRACKING)
    val missing = required.filterNot { it in advertisedOps }
    if (missing.isNotEmpty()) {
        log("TRACKING SKIP missing advertised ops=${missing.joinToString(" ") { hex4(it) }}")
        return emptyList()
    }

    suspend fun grabPackets(count: Int): TrackingProbeCapture {
        val packets = mutableListOf<LiveViewPacket>()
        var attempts = 0
        while (packets.size < count && attempts < count * 4) {
            attempts++
            val packet = labGrabFrame()
            if (packet == null) {
                delay(40)
                continue
            }
            packets += packet
            if (packets.size == 1 || packets.size % 4 == 0) {
                onFrame(packet.bytes.copyOfRange(packet.jpegOffset, packet.bytes.size))
            }
        }
        return TrackingProbeCapture(
            packets = packets,
            selectedFrames = packets.mapNotNull { it.metadata?.selectedFocusFrame }
        )
    }

    var trackingMayBeActive = false

    suspend fun runTrackingCommand(
        label: String,
        code: Int,
        vararg params: Int
    ): Int {
        log(
            "TRACKING COMMAND $label send op=${hex4(code)} params=" +
                params.joinToString(",", prefix = "[", postfix = "]")
        )
        val rc = labCommand(code, *params).first
        if (code == Lab.NK_START_TRACKING && rc == Lab.OK) {
            trackingMayBeActive = true
            subjectTrackingActive = true
        }
        log("TRACKING COMMAND $label resp=${hex4(rc)}")
        return rc
    }

    suspend fun endTracking(label: String): Int? {
        if (!trackingMayBeActive) {
            log("TRACKING $label EndTracking SKIP reason=not-started")
            return null
        }
        log("TRACKING COMMAND $label EndTracking send op=${hex4(Lab.NK_END_TRACKING)}")
        val rc = labCommand(Lab.NK_END_TRACKING).first
        log("TRACKING $label EndTracking resp=${hex4(rc)}")
        if (rc == Lab.OK) {
            trackingMayBeActive = false
            subjectTrackingActive = false
        }
        delay(160)
        return rc
    }

    val baseline = grabPackets(5)
    val first = baseline.packets.firstOrNull()
    val trackingWidth = first?.metadata?.trackingCoordinateWidth
    val trackingHeight = first?.metadata?.trackingCoordinateHeight
    val focusWidth = first?.metadata?.focusCoordinateWidth
    val focusHeight = first?.metadata?.focusCoordinateHeight
    if (
        trackingWidth == null || trackingHeight == null ||
        focusWidth == null || focusHeight == null ||
        trackingWidth < 2 || trackingHeight < 2 || focusWidth < 2 || focusHeight < 2
    ) {
        log(
            "TRACKING SKIP enhanced AF coordinate grid unavailable; " +
                "frames=${baseline.packets.size} metadata=${baseline.packets.count { it.metadata != null }}"
        )
        return emptyList()
    }
    val trackingX = (trackingWidth - 1) / 2
    val trackingY = (trackingHeight - 1) / 2
    val focusX = (focusWidth - 1) / 2
    val focusY = (focusHeight - 1) / 2
    val baselinePacket = checkNotNull(first)
    val baselineHeader = baselinePacket.bytes.copyOfRange(0, baselinePacket.jpegOffset)
    log(
        "TRACKING baseline frames=${baseline.packets.size} selected=${baseline.selectedFrames.size} " +
            "trackingGrid=${trackingWidth}x$trackingHeight target=($trackingX,$trackingY) " +
            "focusGrid=${focusWidth}x$focusHeight target=($focusX,$focusY)"
    )
    delay(1_200)

    val results = mutableListOf<TrackingProbeVariantResult>()

    suspend fun runVariant(
        name: String,
        commands: suspend (MutableList<String>) -> Unit
    ) {
        val commandLog = mutableListOf<String>()
        commands(commandLog)
        val capture = grabPackets(18)
        val centers = capture.selectedFrames
        val xRange = centers.takeIf { it.isNotEmpty() }
            ?.let { it.maxOf { f -> f.centerX } - it.minOf { f -> f.centerX } }
        val yRange = centers.takeIf { it.isNotEmpty() }
            ?.let { it.maxOf { f -> f.centerY } - it.minOf { f -> f.centerY } }
        val frameCounts = capture.packets.mapNotNull { packet ->
            packet.bytes.takeIf { packet.jpegOffset > 45 }?.get(44)?.toInt()?.and(0xFF)
        }.groupingBy { it }.eachCount()
        val selectedIndices = capture.packets.mapNotNull { packet ->
            packet.bytes.takeIf { packet.jpegOffset > 45 }?.get(45)?.toInt()?.and(0xFF)
        }.toSet()
        log(
            "TRACKING RESULT $name commands=${commandLog.joinToString(",")} " +
                "frames=${capture.packets.size} metadata=${capture.packets.count { it.metadata != null }} " +
                "selected=${centers.size} frameCounts=$frameCounts selectedIndices=$selectedIndices " +
                "range=${xRange?.let { "%.4f".format(it) } ?: "n/a"}," +
                "${yRange?.let { "%.4f".format(it) } ?: "n/a"} verdict=" +
                if (capture.motionConfirmed) "CAMERA_FRAME_MOTION_CONFIRMED" else "NOT_CONFIRMED"
        )
        log("TRACKING HEADER_DIFF $name ${trackingHeaderDiff(baselineHeader, capture.packets)}")
        results += TrackingProbeVariantResult(name, commandLog, capture)
        val cleanupRc = endTracking("$name/cleanup")
        check(cleanupRc == null || cleanupRc == Lab.OK) {
            "$name EndTracking failed: ${hex4(checkNotNull(cleanupRc))}"
        }
    }

    try {
        runVariant("MOVE_THEN_START") { commands ->
            val move = runTrackingCommand(
                "MOVE_THEN_START/ChangeAfArea",
                Lab.NK_CHANGE_AF_AREA,
                focusX,
                focusY
            )
            commands += "ChangeAfArea=${hex4(move)}"
            delay(80)
            val start = runTrackingCommand(
                "MOVE_THEN_START/StartTracking",
                Lab.NK_START_TRACKING
            )
            commands += "StartTracking()=${hex4(start)}"
        }
        runVariant("START_THEN_MOVE") { commands ->
            val start = runTrackingCommand(
                "START_THEN_MOVE/StartTracking",
                Lab.NK_START_TRACKING
            )
            commands += "StartTracking()=${hex4(start)}"
            delay(80)
            val move = runTrackingCommand(
                "START_THEN_MOVE/ChangeAfArea",
                Lab.NK_CHANGE_AF_AREA,
                focusX,
                focusY
            )
            commands += "ChangeAfArea=${hex4(move)}"
        }
        runVariant("START_WITH_XY") { commands ->
            val start = runTrackingCommand(
                "START_WITH_XY/StartTracking",
                Lab.NK_START_TRACKING,
                trackingX,
                trackingY
            )
            commands += "StartTracking(x,y)=${hex4(start)}"
        }
        runVariant("MOVE_START_AF") { commands ->
            val move = runTrackingCommand(
                "MOVE_START_AF/ChangeAfArea",
                Lab.NK_CHANGE_AF_AREA,
                focusX,
                focusY
            )
            commands += "ChangeAfArea=${hex4(move)}"
            delay(80)
            val start = runTrackingCommand(
                "MOVE_START_AF/StartTracking",
                Lab.NK_START_TRACKING
            )
            commands += "StartTracking()=${hex4(start)}"
            if (Lab.NK_AF_DRIVE in advertisedOps) {
                delay(80)
                val af = runTrackingCommand("MOVE_START_AF/AfDrive", Lab.NK_AF_DRIVE)
                commands += "AfDrive=${hex4(af)}"
            } else {
                commands += "AfDrive=NOT_ADVERTISED"
            }
        }
    } finally {
        withContext(NonCancellable) {
            if (trackingMayBeActive) {
                runCatching { endTracking("final-cleanup") }
            }
        }
    }

    val confirmed = results.filter { it.capture.motionConfirmed }.map { it.name }
    log(
        "TRACKING VERDICT confirmed=" +
            if (confirmed.isEmpty()) "<none>" else confirmed.joinToString(",")
    )
    return results
}

// ============================ 一次性完整探测 ============================

/**
 * 完整探测：DeviceInfo 全量码表 → Nikon 厂商扩展码表 → 所有已广告属性的描述与当前值
 * （包含完整原始十六进制，便于离线分析未知属性）→ 事件轮询 → Live View 试取 8 帧
 * （经 [onFrame] 回显）→ 收尾 EndLiveView。
 *
 * 安全边界：
 * - 不调用未知操作码；只列出相机广告的操作码。
 * - 普通属性全部只读；只有明确报告为 RW、标量且给出 enum/range 的数字变焦候选
 *   会临时试写。每次写入都回读，整个档位扫描由 finally 恢复原始字节。
 * - 不把机身序列号写进可分享日志。
 * - 除相机广告的属性外，只额外只读查询 App 已知的兼容属性。
 *
 * IO 异常向上抛（socket 已死，继续无意义）；协议级失败（非 OK 响应码）逐条记录后继续。
 */
suspend fun NikonCamera.runLabProbe(
    log: suspend (String) -> Unit,
    onFrame: suspend (ByteArray) -> Unit
) {
    val t0 = System.currentTimeMillis()
    log("=== ZTransfer capability probe v9 ===")
    log(
        "scope=priority-subject-tracking-command-matrix+camera-frame-proof+" +
            "u32-vendor-codes+u32-property-params+live-view-digital-zoom-roundtrip " +
            "mode=zoom-only-temporary-writes-with-restore"
    )

    // ---- 1. DeviceInfo ----
    val info = cachedDeviceInfo
    if (info == null) log("!! DeviceInfo unavailable from connection cache")
    val ops = info?.operations ?: emptySet()
    info?.let {
        log("Model: ${it.manufacturer} ${it.model}  fw=${it.deviceVersion}")
        log(
            "VendorExt: id=${hex8(it.vendorExtId)} ver=${it.vendorExtVersion}" +
                if (it.vendorExtDesc.isBlank()) "" else " desc=${it.vendorExtDesc.replace('\n', ' ')}"
        )
        log("Serial: <omitted for privacy>")
        log("ops=${it.operations.size} events=${it.events.size} props=${it.props.size}")
        logProbeCodes(log, "DeviceInfo.operations", it.operations, Lab.INTEREST_OPS)
        logProbeCodes(log, "DeviceInfo.events", it.events)
        logProbeCodes(log, "DeviceInfo.properties", it.props, Lab.INTEREST_PROPS)
        val present = Lab.INTEREST_OPS.keys.filter { op -> op in it.operations }
        val missing = Lab.INTEREST_OPS.filterKeys { op -> op !in it.operations }
        log("remote ops OK: " + present.joinToString(" ") { op -> hex4(op) })
        if (missing.isNotEmpty()) {
            log("remote ops MISSING: " +
                    missing.entries.joinToString(" ") { (op, name) -> "${hex4(op)}($name)" })
        }
    }

    // ---- 2. 厂商属性码 ----
    var vendorProps90ca: Set<Int> = emptySet()
    if (Lab.NK_GET_VENDOR_PROP_CODES in ops) {
        val (rc, d) = labCommand(Lab.NK_GET_VENDOR_PROP_CODES)
        if (rc == Lab.OK && d != null) {
            val parsed = runCatching { Cur(d).u16Array().toSet() }
            parsed.onSuccess {
                vendorProps90ca = it
                logProbeCodes(log, "GetVendorPropCodes(0x90CA).properties", it, Lab.INTEREST_PROPS)
            }.onFailure {
                log(
                    "!! GetVendorPropCodes(0x90CA) parse failed: ${it.message}; " +
                        "raw=${probeHex(d)}"
                )
            }
        } else log("GetVendorPropCodes(0x90CA) resp=${hex4(rc)}")
    } else {
        log("GetVendorPropCodes(0x90CA): not advertised")
    }

    // ---- 3. Z8/Z9 世代 GetVendorCodes（0x9439）----
    var vendorProps9439: Set<Int> = emptySet()
    if (Lab.NK_GET_VENDOR_CODES in ops) {
        // libgphoto2 的 Nikon 实现固定传 0x0D，并按 u32 数组接收属性码。
        val kind = 0x0D
        val (rc, d) = labCommand(Lab.NK_GET_VENDOR_CODES, kind)
        if (rc == Lab.OK && d != null) {
            // 旧探测按 u16 读取会把每个扩展码拆成“低 16 位 + 0”，正是新属性消失的根因。
            val parsed = runCatching { parseVendorCodes32(d) }
            parsed.onSuccess {
                vendorProps9439 = it
                logProbeCodes(
                    log,
                    "GetVendorCodes(0x9439,0x0D).properties",
                    it,
                    Lab.INTEREST_PROPS
                )
            }.onFailure {
                log(
                    "!! GetVendorCodes(0x9439,0x0D) parse failed: ${it.message}; " +
                        "raw=${probeHex(d)}"
                )
            }
        } else {
            log("GetVendorCodes(0x9439, 0x0D) resp=${hex4(rc)}")
        }
    } else {
        log("GetVendorCodes(0x9439): not advertised")
    }

    val allAdvertisedOps = ops
    val advertised = (info?.props ?: emptySet()) + vendorProps90ca + vendorProps9439
    logProbeCodes(log, "Merged.operations", allAdvertisedOps, Lab.INTEREST_OPS)
    logProbeCodes(log, "Merged.properties", advertised, Lab.INTEREST_PROPS)
    log(
        "PowerZoom opcode ${hex4(Lab.NK_POWER_ZOOM_BY_FOCAL_LENGTH)}: " +
            if (Lab.NK_POWER_ZOOM_BY_FOCAL_LENGTH in allAdvertisedOps) "ADVERTISED"
            else "NOT_ADVERTISED"
    )

    // ---- 4. 所有已广告属性 + App 已知隐藏属性的 GetDevicePropDesc/GetDevicePropValue ----
    // Subject tracking is why this probe is currently being run. Keep it ahead of the exhaustive
    // property survey: that survey can take several minutes on bodies with hundreds of vendor
    // properties, so a report copied before completion must still contain the tracking evidence.
    var lvOk = false
    var trackingProbeResults: List<TrackingProbeVariantResult> = emptyList()
    log("--- priority subject-tracking live view test ---")
    if (Lab.NK_START_LIVE_VIEW !in ops) {
        log("StartLiveView not advertised - trying anyway")
    }
    logTrackingFocusProperties(log)
    if (labStartLiveView(log)) {
        lvOk = true
        try {
            trackingProbeResults = runSubjectTrackingProbe(ops, log, onFrame)
        } finally {
            withContext(NonCancellable) {
                val endRc = runCatching { labEndLiveView() }.getOrNull()
                log(
                    if (endRc != null) {
                        "Priority tracking EndLiveView(0x9202) resp=${hex4(endRc)}"
                    } else {
                        "!! Priority tracking EndLiveView(0x9202) failed"
                    }
                )
            }
        }
    }
    val earlyConfirmedTracking = trackingProbeResults
        .filter { it.capture.motionConfirmed }
        .joinToString(",") { it.name }
    log(
        "PRIORITY TRACKING SUMMARY: " +
            if (earlyConfirmedTracking.isNotEmpty()) {
                "CAMERA_FRAME_MOTION_CONFIRMED via=$earlyConfirmedTracking"
            } else if (trackingProbeResults.isNotEmpty()) {
                "NOT_CONFIRMED (inspect TRACKING RESULT/HEADER_DIFF above)"
            } else {
                "NOT_TESTED"
            }
    )

    val probeProps = (advertised + Lab.INTEREST_PROPS.keys).sorted()
    var descOkCount = 0
    var valueOkCount = 0
    val digitalZoomDesc = mutableMapOf<Int, String>()
    val digitalZoomValue = mutableMapOf<Int, String>()
    val digitalZoomParsedDesc = mutableMapOf<Int, ProbePropDescData>()
    val digitalZoomDescRoute = mutableMapOf<Int, Int>()
    val digitalZoomValueRoute = mutableMapOf<Int, Int>()
    val digitalZoomValueRaw = mutableMapOf<Int, ByteArray>()
    val digitalZoomSweepResult = mutableMapOf<Int, String>()
    val digitalZoomControlConfirmed = mutableSetOf<Int>()
    log("--- property survey (${probeProps.size}) ---")
    log("Each DESC/VALUE raw field is complete little-endian payload; unknown codes are intentional.")
    for ((index, prop) in probeProps.withIndex()) {
        val name = Lab.INTEREST_PROPS[prop] ?: "Unknown"
        val sources = buildList {
            if (prop in (info?.props ?: emptySet())) add("device")
            if (prop in vendorProps90ca) add("90CA")
            if (prop in vendorProps9439) add("9439")
            if (prop in Lab.INTEREST_PROPS && prop !in advertised) add("known-fallback")
        }.joinToString("+").ifEmpty { "unknown" }

        // PTP 命令参数本身是 u32，0x1D033 直接以完整 Int 传给标准 0x1014。
        val descOp = Lab.GET_DEVICE_PROP_DESC
        val (rc, d) = labCommand(descOp, prop)
        if (rc == Lab.OK && d != null) {
            descOkCount++
            val parsed = runCatching { parsePropDesc(prop, d) }
            val txt = parsed.getOrElse { "parse failed: ${it.message}" }
            log(
                "PROP ${index + 1}/${probeProps.size} ${hexCode(prop)} $name " +
                    "src=$sources DESC via=${hex4(descOp)} resp=${hex4(rc)} " +
                    "bytes=${d.size} $txt raw=${probeHex(d)}"
            )
            if (prop in Lab.DIGITAL_ZOOM_PROPS) {
                digitalZoomDesc[prop] = "OK $txt"
                runCatching { parseProbePropDescData(prop, d) }.getOrNull()?.let {
                    digitalZoomParsedDesc[prop] = it
                    digitalZoomDescRoute[prop] = descOp
                }
            }
        } else {
            log(
                "PROP ${index + 1}/${probeProps.size} ${hexCode(prop)} $name " +
                    "src=$sources DESC via=${hex4(descOp)} resp=${hex4(rc)} " +
                    "bytes=${d?.size ?: 0} raw=${probeHex(d)}"
            )
            if (prop in Lab.DIGITAL_ZOOM_PROPS) {
                digitalZoomDesc[prop] = "resp=${hex4(rc)}"
            }
        }

        // 数字变焦候选即使没有出现在 DeviceInfo 中也强制只读查询。Nikon 的隐藏厂商
        // 属性经常可用却不广告；失败只会返回响应码，不会改变相机状态。
        val valueOp = Lab.GET_DEVICE_PROP_VALUE
        val readValue = valueOp in allAdvertisedOps ||
            prop in Lab.DIGITAL_ZOOM_PROPS
        if (readValue) {
            val (vrc, vd) = labCommand(valueOp, prop)
            if (vrc == Lab.OK && vd != null) valueOkCount++
            log(
                "PROP ${index + 1}/${probeProps.size} ${hexCode(prop)} $name " +
                    "VALUE via=${hex4(valueOp)} resp=${hex4(vrc)} " +
                    "bytes=${vd?.size ?: 0} raw=${probeHex(vd)}"
            )
            if (prop in Lab.DIGITAL_ZOOM_PROPS) {
                digitalZoomValue[prop] =
                    "resp=${hex4(vrc)} bytes=${vd?.size ?: 0} raw=${probeHex(vd)}"
                if (vrc == Lab.OK && vd != null) {
                    digitalZoomValueRaw[prop] = vd
                    digitalZoomValueRoute[prop] = valueOp
                }
            }
        } else if (index == 0) {
            log("GetDevicePropValue(0x1015): not advertised; VALUE survey skipped")
        }

        if ((index + 1) % 20 == 0 || index == probeProps.lastIndex) {
            log(
                "property progress=${index + 1}/${probeProps.size} " +
                    "descOK=$descOkCount valueOK=$valueOkCount"
            )
        }
    }

    // ---- 5. 数字变焦专检汇总 ----
    // DESC 中 RW/RO 决定能否控制，enum/range 给出完整档位；VALUE 保留当前值原始编码。
    // 这里只汇总上面的只读结果，不重复发命令。
    val probeMovieMode = runCatching { rcGetMovieMode() }.getOrNull()
    log("--- digital zoom focus ---")
    log(
        "DIGITAL_ZOOM camera-selector=" +
            when (probeMovieMode) {
                true -> "MOVIE"
                false -> "PHOTO"
                null -> "UNKNOWN"
            }
    )
    Lab.DIGITAL_ZOOM_PROPS.forEach { (prop, name) ->
        val meaning = when (prop) {
            Lab.PROP_NK_LV_IMAGE_ZOOM_RATIO -> "live-view-magnification-ratio"
            Lab.PROP_NK_LV_ZOOM_AREA -> "live-view-magnified-area"
            Lab.PROP_NK_HI_RES_ZOOM -> "movie-hi-res-digital-zoom"
            else -> "captured-output-digital-zoom"
        }
        log(
            "DIGITAL_ZOOM ${hexCode(prop)} $name meaning=$meaning " +
                "advertised=${if (prop in advertised) "YES" else "NO"} " +
                "DESC ${digitalZoomDesc[prop] ?: "NOT_QUERIED"} " +
                "VALUE ${digitalZoomValue[prop] ?: "NOT_QUERIED"}"
        )
    }
    log("DIGITAL_ZOOM 32-bit property IDs use standard PTP 0x1014/0x1015/0x1016")
    log(
        "DIGITAL_ZOOM note: the live-view stage repeats reads after LV starts; " +
            "RW scalar enum/range properties are temporarily swept and restored."
    )
    if (probeMovieMode != true) {
        log(
            "DIGITAL_ZOOM note: Hi-Res Zoom may only be exposed in movie mode; " +
                "if 0x1D033 is unavailable, move the physical selector to movie and probe again."
        )
    }

    // ---- 6. 电子水平仪 AngleLevel (0xD067) 专检 ----
    // Z 30 为首要目标机身，此属性是水平仪唯一数据源（libgphoto2 ptp.h 定义
    // PTP_DPC_NIKON_AngleLevel = 0xD067，Z 30/Z 50/Z 8/Z 9/Z 6iii 全世代共用）。
    // 属性不支持 = toggle 拒绝锁存 + devLog，不画假角度。
    val (alrc, ald) = labCommand(Lab.GET_DEVICE_PROP_VALUE, Lab.PROP_NK_ANGLE_LEVEL)
    if (alrc == Lab.OK && ald != null && ald.size >= 4) {
        val raw = ald.indices.fold(0L) { acc, i ->
            acc or ((ald[i].toLong() and 0xFF) shl (8 * i))
        }
        val rollDeg = raw / 65536.0   // 16.16 定点度数
        log("AngleLevel(0xD067) raw=$raw (INT32 16.16 fixed) roll=%.1f° source=0xD067 poll".format(rollDeg))
    } else {
        log("!! AngleLevel(0xD067) resp=${hex4(alrc)} — level NOT available on this body")
    }

    // ---- 7. 事件轮询 ----
    if (Lab.NK_GET_EVENT in ops) {
        val (rc, d) = labCommand(Lab.NK_GET_EVENT)
        if (rc == Lab.OK && d != null) {
            val evts = runCatching { parseNikonEvents(d) }.getOrDefault(emptyList())
            log("GetEvent(0x90C7): ${evts.size} pending" +
                    if (evts.isEmpty()) "" else " " + evts.joinToString(" ") { (c, p) -> "${hex4(c)}(${hex8(p)})" })
        } else log("GetEvent(0x90C7) resp=${hex4(rc)}")
    }

    suspend fun readDigitalZoomInLiveView() {
        log("--- digital zoom live-view re-read ---")
        for ((prop, name) in Lab.DIGITAL_ZOOM_PROPS) {
            val descRoute = Lab.GET_DEVICE_PROP_DESC
            val (descRc, descData) = labCommand(descRoute, prop)
            val parsed =
                if (descRc == Lab.OK && descData != null) {
                    runCatching { parseProbePropDescData(prop, descData) }
                } else {
                    null
                }
            val descDetail =
                parsed?.fold(
                    onSuccess = {
                        "${parsePropDesc(prop, checkNotNull(descData))} raw=${probeHex(descData)}"
                    },
                    onFailure = {
                        "parse_failed=${it.message} raw=${probeHex(descData)}"
                    }
                ) ?: "raw=${probeHex(descData)}"
            log(
                "DIGITAL_ZOOM_READ stage=live-view prop=${hexCode(prop)} $name " +
                    "DESC via=${hex4(descRoute)} resp=${hex4(descRc)} " +
                    "bytes=${descData?.size ?: 0} $descDetail"
            )
            parsed?.getOrNull()?.let { descriptor ->
                digitalZoomParsedDesc[prop] = descriptor
                digitalZoomDescRoute[prop] = descRoute
                digitalZoomDesc[prop] =
                    "OK ${parsePropDesc(prop, checkNotNull(descData))} via=${hex4(descRoute)}"
            }

            val valueRoute = Lab.GET_DEVICE_PROP_VALUE
            val (valueRc, valueData) = labCommand(valueRoute, prop)
            log(
                "DIGITAL_ZOOM_READ stage=live-view prop=${hexCode(prop)} $name " +
                    "VALUE via=${hex4(valueRoute)} resp=${hex4(valueRc)} " +
                    "bytes=${valueData?.size ?: 0} raw=${probeHex(valueData)}"
            )
            if (valueRc == Lab.OK && valueData != null) {
                digitalZoomValueRaw[prop] = valueData
                digitalZoomValueRoute[prop] = valueRoute
                digitalZoomValue[prop] =
                    "resp=${hex4(valueRc)} bytes=${valueData.size} " +
                        "raw=${probeHex(valueData)} via=${hex4(valueRoute)}"
            }
        }
    }

    suspend fun sweepWritableDigitalZoom() {
        log("--- digital zoom controlled write/readback sweep ---")
        for ((prop, name) in Lab.DIGITAL_ZOOM_PROPS) {
            val desc = digitalZoomParsedDesc[prop]
            val original = digitalZoomValueRaw[prop]
            val valueRoute = digitalZoomValueRoute[prop]
            val descRoute = digitalZoomDescRoute[prop]
            val scalarBytes = desc?.let { scalarSize(it.dataType) }
            val writeRoute =
                if (
                    descRoute == Lab.GET_DEVICE_PROP_DESC &&
                    Lab.SET_DEVICE_PROP_VALUE in allAdvertisedOps
                ) {
                    Lab.SET_DEVICE_PROP_VALUE
                } else {
                    null
                }
            val skipReason = when {
                desc == null -> "no-parseable-desc"
                !desc.writable -> "read-only"
                !desc.currentIsScalar || scalarBytes == null -> "non-scalar"
                original == null || valueRoute == null -> "no-readable-current-value"
                original.size != scalarBytes ->
                    "value-size-${original.size}-expected-$scalarBytes"
                writeRoute == null -> "no-matching-advertised-set-route"
                else -> null
            }
            if (skipReason != null) {
                digitalZoomSweepResult[prop] = "SKIP($skipReason)"
                log(
                    "DIGITAL_ZOOM_SWEEP prop=${hexCode(prop)} $name SKIP reason=$skipReason"
                )
                continue
            }

            val activeDesc = checkNotNull(desc)
            val originalRaw = checkNotNull(original)
            val activeDescRoute = checkNotNull(descRoute)
            val activeValueRoute = checkNotNull(valueRoute)
            val activeWriteRoute = checkNotNull(writeRoute)
            val candidates = digitalZoomProbeValues(activeDesc).map {
                it to encodeScalar(activeDesc.dataType, it)
            }.filter { (_, raw) -> !raw.contentEquals(originalRaw) }
            if (candidates.isEmpty()) {
                digitalZoomSweepResult[prop] = "SKIP(no-alternate-enum-or-range-value)"
                log(
                    "DIGITAL_ZOOM_SWEEP prop=${hexCode(prop)} $name SKIP " +
                        "reason=no-alternate-enum-or-range-value"
                )
                continue
            }

            log(
                "DIGITAL_ZOOM_SWEEP prop=${hexCode(prop)} $name " +
                    "descVia=${hex4(activeDescRoute)} readVia=${hex4(activeValueRoute)} " +
                    "writeVia=${hex4(activeWriteRoute)} type=${hex4(activeDesc.dataType)} " +
                    "original=${probeHex(originalRaw)} candidates=" +
                    candidates.joinToString(",") { (value, raw) ->
                        "$value:${probeHex(raw)}"
                    }
            )

            var acceptedValues = 0
            var sweepError: String? = null
            try {
                for ((value, raw) in candidates) {
                    val setRc = labSetProp(prop, raw)
                    delay(220)
                    val (readRc, readRaw) = labCommand(activeValueRoute, prop)
                    val changed = readRc == Lab.OK && readRaw != null &&
                        !readRaw.contentEquals(originalRaw)
                    val matched = readRc == Lab.OK && readRaw?.contentEquals(raw) == true
                    if (setRc == Lab.OK && matched) {
                        acceptedValues++
                        digitalZoomControlConfirmed += prop
                    }
                    log(
                        "DIGITAL_ZOOM_STEP prop=${hexCode(prop)} requested=$value " +
                            "write=${hex4(setRc)} read=${hex4(readRc)} " +
                            "readRaw=${probeHex(readRaw)} changed=$changed matched=$matched"
                    )
                    if (setRc != Lab.OK) break

                    if (Lab.NK_GET_EVENT in allAdvertisedOps) {
                        val (eventRc, eventData) = labCommand(Lab.NK_GET_EVENT)
                        val events = if (eventRc == Lab.OK && eventData != null) {
                            runCatching { parseNikonEvents(eventData) }.getOrDefault(emptyList())
                        } else {
                            emptyList()
                        }
                        log(
                            "DIGITAL_ZOOM_STEP events resp=${hex4(eventRc)} " +
                                events.joinToString(" ") { (code, param) ->
                                    "${hex4(code)}(${hex8(param)})"
                                }.ifEmpty { "<none>" }
                        )
                    }
                    if (Lab.NK_GET_EVENT_EX in allAdvertisedOps) {
                        val (eventExRc, eventExData) = labCommand(Lab.NK_GET_EVENT_EX)
                        log(
                            "DIGITAL_ZOOM_STEP eventsEx resp=${hex4(eventExRc)} " +
                                "bytes=${eventExData?.size ?: 0} raw=${probeHex(eventExData)}"
                        )
                    }

                    var frameInfo: LiveViewPacket? = null
                    repeat(6) {
                        if (frameInfo == null) {
                            frameInfo = labGrabFrame()
                            if (frameInfo == null) delay(40)
                        }
                    }
                    frameInfo?.let { packet ->
                        val jpeg =
                            packet.bytes.copyOfRange(packet.jpegOffset, packet.bytes.size)
                        val crc = CRC32().apply { update(jpeg) }.value
                        log(
                            "DIGITAL_ZOOM_STEP frame bytes=${jpeg.size} " +
                                "jpegOffset=${packet.jpegOffset} crc32=${hex8(crc)}"
                        )
                        onFrame(jpeg)
                        delay(300)
                    } ?: log("DIGITAL_ZOOM_STEP frame=<unavailable>")
                }
            } catch (probeError: Exception) {
                if (probeError is CancellationException) throw probeError
                sweepError = "${probeError.javaClass.simpleName}:${probeError.message}"
                log(
                    "!! DIGITAL_ZOOM_SWEEP prop=${hexCode(prop)} FAILED $sweepError"
                )
            } finally {
                // 用户退出页面会取消探测协程；恢复必须脱离取消状态继续执行。
                withContext(NonCancellable) {
                    try {
                        val restoreRc = labSetProp(prop, originalRaw)
                        delay(180)
                        val (verifyRc, verifyRaw) = labCommand(activeValueRoute, prop)
                        val restored =
                            verifyRc == Lab.OK && verifyRaw?.contentEquals(originalRaw) == true
                        digitalZoomSweepResult[prop] =
                            "accepted=$acceptedValues/${candidates.size} restored=$restored " +
                                "writeVia=${hex4(activeWriteRoute)}" +
                                (sweepError?.let { " error=$it" } ?: "")
                        log(
                            "DIGITAL_ZOOM_RESTORE prop=${hexCode(prop)} " +
                                "write=${hex4(restoreRc)} verify=${hex4(verifyRc)} " +
                                "raw=${probeHex(verifyRaw)} restored=$restored"
                        )
                    } catch (restoreError: Exception) {
                        digitalZoomSweepResult[prop] =
                            "accepted=$acceptedValues/${candidates.size} restore=FAILED " +
                                "error=${restoreError.message}"
                        log(
                            "!! DIGITAL_ZOOM_RESTORE prop=${hexCode(prop)} FAILED " +
                                "${restoreError.javaClass.simpleName}: ${restoreError.message}"
                        )
                    }
                }
            }
        }
    }

    // ---- 8. Live View 试取帧 ----
    log("--- live view test ---")
    if (Lab.NK_START_LIVE_VIEW !in ops) log("StartLiveView not advertised - trying anyway")
    if (labStartLiveView(log)) {
        lvOk = true
        try {
            readDigitalZoomInLiveView()
            sweepWritableDigitalZoom()
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
                if (got > 0) {
                    log(
                        "LV: $got frames ok / $attempts polls, ~${lastTotal / 1024}KB " +
                            "jpeg@$soiOff, avg ${totalMs / got}ms " +
                            "(~%.1f fps ceiling)".format(1000f / (totalMs / got))
                    )
                }
            } catch (e: Exception) {
                if (e is CancellationException) throw e
                log("!! LV frame error: ${e.message}")
            }
        } finally {
            withContext(NonCancellable) {
                val endRc = runCatching { labEndLiveView() }.getOrNull()
                log(
                    if (endRc != null) {
                        "EndLiveView(0x9202) resp=${hex4(endRc)}"
                    } else {
                        "!! EndLiveView(0x9202) failed"
                    }
                )
            }
        }
    }

    // ---- 9. 结论 ----
    log("--- verdict ---")
    log("property survey: $descOkCount/${probeProps.size} desc, $valueOkCount/${probeProps.size} value")
    log(
        "power zoom op:   " +
            if (Lab.NK_POWER_ZOOM_BY_FOCAL_LENGTH in allAdvertisedOps) {
                "${hex4(Lab.NK_POWER_ZOOM_BY_FOCAL_LENGTH)} ADVERTISED"
            } else {
                "NOT ADVERTISED"
            }
    )
    log("live view:      ${if (lvOk) "YES" else "NO"}")
    val confirmedTracking = trackingProbeResults
        .filter { it.capture.motionConfirmed }
        .joinToString(",") { it.name }
    log(
        "subject tracking: " +
            if (confirmedTracking.isNotEmpty()) {
                "CAMERA_FRAME_MOTION_CONFIRMED via=$confirmedTracking"
            } else if (trackingProbeResults.isNotEmpty()) {
                "NOT_CONFIRMED (inspect TRACKING RESULT/HEADER_DIFF)"
            } else {
                "NOT_TESTED"
            }
    )
    log(
        "live-view zoom: " +
            if (digitalZoomDesc[Lab.PROP_NK_LV_IMAGE_ZOOM_RATIO]?.startsWith("OK ") == true) {
                "0xD1A3 DESC_OK (inspect RW/RO and levels above)"
            } else {
                "0xD1A3 UNAVAILABLE"
            }
    )
    log(
        "digital zoom:   " +
            if (digitalZoomDesc[Lab.PROP_DIGITAL_ZOOM]?.startsWith("OK ") == true) {
                "0x5016 DESC_OK (inspect RW/RO and levels above)"
            } else {
                "0x5016 UNAVAILABLE"
            }
    )
    log(
        "hi-res zoom:    " +
            if (digitalZoomDesc[Lab.PROP_NK_HI_RES_ZOOM]?.startsWith("OK ") == true) {
                "0x1D033 DESC_OK (extended Nikon property)"
            } else {
                "0x1D033 UNAVAILABLE"
            }
    )
    log(
        "zoom area:      " +
            if (digitalZoomDesc[Lab.PROP_NK_LV_ZOOM_AREA]?.startsWith("OK ") == true) {
                "0xD1BD DESC_OK (inspect payload/RO status above)"
            } else {
                "0xD1BD UNAVAILABLE"
            }
    )
    Lab.DIGITAL_ZOOM_PROPS.forEach { (prop, name) ->
        val control =
            if (prop in digitalZoomControlConfirmed) "REMOTE_CONTROL_CONFIRMED"
            else "not-confirmed"
        log(
            "zoom candidate ${hexCode(prop)} $name: $control; " +
                "sweep=${digitalZoomSweepResult[prop] ?: "NOT_RUN"}"
        )
    }
    log("angle level:    ${if (alrc == Lab.OK && ald != null && ald.size >= 4) "0xD067 OK" else "UNAVAILABLE"}")
    log("capture opcode: ${if (Lab.NK_CAPTURE_REC_IN_MEDIA in ops || Lab.NK_CAPTURE_REC_IN_SDRAM in ops) "advertised" else "MISSING"}")
    log("event polling:  ${if (Lab.NK_GET_EVENT in ops || Lab.NK_GET_EVENT_EX in ops) "advertised" else "MISSING"}")
    log("=== probe done in ${System.currentTimeMillis() - t0}ms ===")
}

