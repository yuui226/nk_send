package com.ztransfer.protocol

import android.content.Context
import com.ztransfer.R

object PtpConstants {
    // PTP/IP 包类型
    const val INIT_CMD_REQ = 1
    const val INIT_CMD_ACK = 2
    const val INIT_EVT_REQ = 3
    const val INIT_EVT_ACK = 4
    const val INIT_FAIL = 5
    const val CMD_REQUEST = 6
    const val CMD_RESPONSE = 7
    // 8 = Event 包（事件通道上收到后直接忽略，无需常量）
    const val START_DATA_PACKET = 9
    const val DATA_PACKET = 10
    const val CANCEL = 11          // Cancel 包：请求对端中止指定事务的数据阶段
    const val END_DATA_PACKET = 12
    const val PING = 13
    const val PONG = 14

    // PTP 命令码
    const val OPEN_SESSION = 0x1002
    const val CLOSE_SESSION = 0x1003
    const val GET_STORAGE_IDS = 0x1004
    const val GET_OBJECT_HANDLES = 0x1007
    const val GET_OBJECT_INFO = 0x1008
    const val GET_OBJECT = 0x1009
    const val GET_THUMB = 0x100A

    // 响应码
    const val RESPONSE_OK = 0x2001
    const val SESSION_ALREADY_OPEN = 0x201E
    // PTP 规范：0x2009 Invalid_Object_Handle / 0x2010 No_Thumbnail_Present。
    // 用于区分"确认无缩略图"（可负缓存）与"瞬时失败"（如设备忙，绝不能负缓存）。
    const val INVALID_OBJECT_HANDLE = 0x2009
    const val NO_THUMBNAIL_PRESENT = 0x2010

    // ObjectInfo 的 32 位大小字段报不出 >4GB 对象的真实大小，此时为全 FF 哨兵（无符号）。
    const val SIZE_UNKNOWN = 0xFFFFFFFFL

    // 相机地址
    const val CAMERA_IP = "192.168.1.1"
    const val PTP_PORT = 15740

    // 格式码 -> 扩展名
    val FORMAT_EXT = mapOf(
        0x3001 to ".jpg",
        0x3801 to ".jpg",
        0x3802 to ".tif",
        0x3804 to ".png",
        0x3805 to ".bmp",
        0x3806 to ".gif",
        0x3807 to ".ico",
        0x3808 to ".jpg",
        0x300D to ".mov",
        0x300B to ".avi",
        0x300E to ".mp4",
        0xB101 to ".nef",
        0xB102 to ".nef",
        0xB103 to ".nef",
        0xB104 to ".nef",
        0xB105 to ".nef",
        0xB106 to ".nef",
        0xB801 to ".crw",
        0xB802 to ".cr2",
        0xB803 to ".cr3",
        0xB808 to ".arw",
        0xB809 to ".arw"
    )

    fun getExt(format: Int): String = FORMAT_EXT[format] ?: ".bin"

    // 响应码 -> 文案资源 ID（随系统语言本地化，仅错误路径调用，不在热路径上）。
    private val RESPONSE_MESSAGES = mapOf(
        0x2002 to R.string.ptp_invalid_parameter,
        0x2003 to R.string.ptp_operation_not_supported,
        0x2004 to R.string.ptp_insufficient_storage,
        0x2005 to R.string.ptp_object_not_exist,
        0x2006 to R.string.ptp_storage_full,
        0x2007 to R.string.ptp_file_exists,
        0x2008 to R.string.ptp_no_filename,
        0x2009 to R.string.ptp_file_protected,
        0x200A to R.string.ptp_session_not_open,
        0x200B to R.string.ptp_transfer_cancelled,
        0x200C to R.string.ptp_no_object,
        0x200D to R.string.ptp_incompatible_spec,
        0x200F to R.string.ptp_device_busy,
        0x2010 to R.string.ptp_no_parent,
        0x201E to R.string.ptp_session_already_open,
        0xA801 to R.string.ptp_firmware_error,
        0xA802 to R.string.ptp_storage_unavailable
    )

    // 纯错误翻译器：所有调用点都在排除 RESPONSE_OK 之后才调用，不处理成功码。
    fun translateResponse(context: Context, code: Int): String {
        RESPONSE_MESSAGES[code]?.let { return context.getString(it) }
        val hex = code.toString(16).uppercase()
        return when (code and 0xFF00) {
            0x2000 -> context.getString(R.string.ptp_general_error, hex)
            0xA000 -> context.getString(R.string.ptp_device_error, hex)
            0xA800 -> context.getString(R.string.ptp_firmware_error_code, hex)
            else -> context.getString(R.string.ptp_unknown_error, hex)
        }
    }
}
