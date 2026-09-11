package com.ztransfer.protocol

import android.content.Context
import com.ztransfer.R

// 响应码 -> 文案资源 ID（随系统语言本地化，仅错误路径调用，不在热路径上）。
private val RESPONSE_MESSAGES = mapOf(
    0x2003 to R.string.ptp_session_not_open,
    PtpConstants.OPERATION_NOT_SUPPORTED to R.string.ptp_operation_not_supported,
    0x2006 to R.string.ptp_invalid_parameter,
    PtpConstants.INVALID_OBJECT_HANDLE to R.string.ptp_object_not_exist,
    0x200A to R.string.ptp_operation_not_supported,
    0x200B to R.string.ptp_incompatible_spec,
    0x200C to R.string.ptp_storage_full,
    0x200D to R.string.ptp_file_protected,
    0x200E to R.string.ptp_file_protected,
    0x2013 to R.string.ptp_storage_unavailable,
    0x2014 to R.string.ptp_incompatible_spec,
    0x2015 to R.string.ptp_no_object,
    PtpConstants.DEVICE_BUSY to R.string.ptp_device_busy,
    0x201A to R.string.ptp_no_parent,
    0x201D to R.string.ptp_invalid_parameter,
    0x201E to R.string.ptp_session_already_open,
    0x201F to R.string.ptp_transfer_cancelled,
    0xA801 to R.string.ptp_firmware_error,
    0xA802 to R.string.ptp_storage_unavailable
)

// 纯错误翻译器：所有调用点都在排除 RESPONSE_OK 之后才调用，不处理成功码。
internal fun PtpConstants.translateResponse(context: Context, code: Int): String {
    RESPONSE_MESSAGES[code]?.let { return context.getString(it) }
    val hex = code.toString(16).uppercase()
    return when (code and 0xFF00) {
        0x2000 -> context.getString(R.string.ptp_general_error, hex)
        0xA000 -> context.getString(R.string.ptp_device_error, hex)
        0xA800 -> context.getString(R.string.ptp_firmware_error_code, hex)
        else -> context.getString(R.string.ptp_unknown_error, hex)
    }
}
