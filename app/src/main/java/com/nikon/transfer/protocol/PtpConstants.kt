package com.nikon.transfer.protocol

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

    private val RESPONSE_MESSAGES = mapOf(
        0x2002 to "参数无效",
        0x2003 to "操作不支持",
        0x2004 to "存储空间不足",
        0x2005 to "指定的对象不存在",
        0x2006 to "存储已满",
        0x2007 to "文件已存在",
        0x2008 to "未指定文件名",
        0x2009 to "文件保护",
        0x200A to "会话未打开",
        0x200B to "传输已取消",
        0x200C to "未指定对象",
        0x200D to "规范不兼容",
        0x200F to "设备忙",
        0x2010 to "父对象不存在",
        0x201E to "会话已打开",
        0xA801 to "设备固件错误",
        0xA802 to "存储不可用"
    )

    fun translateResponse(code: Int): String {
        if (code == RESPONSE_OK) return "成功"
        val upper = code and 0xFF00
        val base = RESPONSE_MESSAGES[code]
        if (base != null) return base
        return when (upper) {
            0x2000 -> "通用错误 (0x${code.toString(16).uppercase()})"
            0xA000 -> "设备错误 (0x${code.toString(16).uppercase()})"
            0xA800 -> "固件错误 (0x${code.toString(16).uppercase()})"
            else -> "错误 (0x${code.toString(16).uppercase()})"
        }
    }
}
