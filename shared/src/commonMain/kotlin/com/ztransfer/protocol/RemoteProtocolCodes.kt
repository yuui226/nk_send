package com.ztransfer.protocol

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
