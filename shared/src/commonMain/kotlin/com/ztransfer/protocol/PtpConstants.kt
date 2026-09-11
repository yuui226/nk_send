package com.ztransfer.protocol

object PtpConstants {
    // PTP/IP 包类型
    const val INIT_CMD_REQ = 1
    const val INIT_CMD_ACK = 2
    const val INIT_EVT_REQ = 3
    const val INIT_EVT_ACK = 4
    const val INIT_FAIL = 5
    const val CMD_REQUEST = 6
    const val CMD_RESPONSE = 7
    const val EVENT = 8
    const val START_DATA_PACKET = 9
    const val DATA_PACKET = 10
    const val CANCEL = 11          // Cancel 包：请求对端中止指定事务的数据阶段
    const val END_DATA_PACKET = 12
    const val PING = 13
    const val PONG = 14

    // PTP 命令码
    const val GET_DEVICE_INFO = 0x1001
    const val OPEN_SESSION = 0x1002
    const val CLOSE_SESSION = 0x1003
    const val GET_STORAGE_IDS = 0x1004
    const val GET_OBJECT_HANDLES = 0x1007
    const val GET_OBJECT_INFO = 0x1008
    const val GET_OBJECT = 0x1009
    const val GET_THUMB = 0x100A
    // MTP/PTP 1.1 object-property operations. Paired Nikon STA may deny GetObjectInfo while still
    // exposing ObjectFileName through these narrower metadata operations.
    const val GET_OBJECT_PROP_VALUE = 0x9803
    const val GET_OBJECT_PROP_LIST = 0x9805
    const val OBJECT_PROP_OBJECT_FILE_NAME = 0xDC07
    // Nikon 专有分块读取 (libgphoto2: PTP_OC_NIKON_GetPartialObjectEx)
    // 标准 PTP 0x101B 在 Nikon 机身上不被识别（返回 0x2004），须用此操作码。
    // 参数: handle, offset_low, offset_high, maxsize_low, maxsize_high (均为 u32)
    const val NK_GET_PARTIAL_OBJECT_EX = 0x9431
    // Nikon 专有 64 位文件大小查询 (libgphoto2: PTP_OC_NIKON_GetObjectSize)
    // 标准 ObjectInfo(0x1008) 的 size 字段是 32 位，>4GB 文件报 0xFFFFFFFF；
    // 调此操作码获取真实 64 位字节数。参数: handle，返回 8 字节小端 u64。
    const val NK_GET_OBJECT_SIZE = 0x9421
    // Nikon 批量对象索引（libgphoto2: PTP_OC_NIKON_GetObjectsMetaData）。
    // 参数: storageId, format, association；Z30 返回固定 16 字节记录，包含 handle 与拍摄时间。
    const val NK_GET_OBJECTS_METADATA = 0x9434
    // Nikon camera-generated large preview (libgphoto2: PTP_OC_NIKON_GetLargeThumb).
    // 参数: handle；返回 JPEG 预览，不读取原始照片对象。
    const val NK_GET_LARGE_THUMB = 0x90C4
    // Nikon 专有 FHD 预览图 (libgphoto2: PTP_OC_NIKON_GetFhdPicture)
    // 参数: handle，返回 1920×1080 JPEG。比 GetThumb (160×120) 清晰得多，
    // 用于长按预览提高清晰度；固件不支持时静默回退到缩略图。
    const val NK_GET_FHD_PICTURE = 0x920F
    // Nikon “连接到计算机”首次配对状态下使用的私有操作码（来自实机抓包）。
    const val NK_PAIRING_QUERY = 0x952B
    const val NK_PAIRING_RESULT = 0x935A

    const val EVENT_DEVICE_INFO_CHANGED = 0x4008

    // 响应码
    const val RESPONSE_OK = 0x2001
    // PTP 规范 0x2005 Operation_Not_Supported：机型不支持该操作码时返回。
    // 用于 FHD 预览的会话级熔断（明确不支持才熔断，瞬时错误不误伤）。
    const val OPERATION_NOT_SUPPORTED = 0x2005
    const val DEVICE_BUSY = 0x2019
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
}
