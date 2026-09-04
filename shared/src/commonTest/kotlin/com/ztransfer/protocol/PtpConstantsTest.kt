package com.ztransfer.protocol

import kotlin.test.Test
import kotlin.test.assertEquals

class PtpConstantsTest {
    @Test
    fun packetTypesRemainThePtpIpSequence() {
        assertEquals(
            (1..14).toList(),
            listOf(
                PtpConstants.INIT_CMD_REQ,
                PtpConstants.INIT_CMD_ACK,
                PtpConstants.INIT_EVT_REQ,
                PtpConstants.INIT_EVT_ACK,
                PtpConstants.INIT_FAIL,
                PtpConstants.CMD_REQUEST,
                PtpConstants.CMD_RESPONSE,
                PtpConstants.EVENT,
                PtpConstants.START_DATA_PACKET,
                PtpConstants.DATA_PACKET,
                PtpConstants.CANCEL,
                PtpConstants.END_DATA_PACKET,
                PtpConstants.PING,
                PtpConstants.PONG,
            ),
        )
    }

    @Test
    fun operationAndResponseCodesRemainStable() {
        assertEquals(
            listOf(
                0x1001,
                0x1002,
                0x1003,
                0x1004,
                0x1007,
                0x1008,
                0x1009,
                0x100A,
                0x9803,
                0x9805,
                0xDC07,
                0x9431,
                0x9421,
                0x9434,
                0x90C4,
                0x920F,
                0x952B,
                0x935A,
            ),
            listOf(
                PtpConstants.GET_DEVICE_INFO,
                PtpConstants.OPEN_SESSION,
                PtpConstants.CLOSE_SESSION,
                PtpConstants.GET_STORAGE_IDS,
                PtpConstants.GET_OBJECT_HANDLES,
                PtpConstants.GET_OBJECT_INFO,
                PtpConstants.GET_OBJECT,
                PtpConstants.GET_THUMB,
                PtpConstants.GET_OBJECT_PROP_VALUE,
                PtpConstants.GET_OBJECT_PROP_LIST,
                PtpConstants.OBJECT_PROP_OBJECT_FILE_NAME,
                PtpConstants.NK_GET_PARTIAL_OBJECT_EX,
                PtpConstants.NK_GET_OBJECT_SIZE,
                PtpConstants.NK_GET_OBJECTS_METADATA,
                PtpConstants.NK_GET_LARGE_THUMB,
                PtpConstants.NK_GET_FHD_PICTURE,
                PtpConstants.NK_PAIRING_QUERY,
                PtpConstants.NK_PAIRING_RESULT,
            ),
        )
        assertEquals(0x4008, PtpConstants.EVENT_DEVICE_INFO_CHANGED)
        assertEquals(0x2001, PtpConstants.RESPONSE_OK)
        assertEquals(0x2005, PtpConstants.OPERATION_NOT_SUPPORTED)
        assertEquals(0x2009, PtpConstants.INVALID_OBJECT_HANDLE)
        assertEquals(0x2010, PtpConstants.NO_THUMBNAIL_PRESENT)
        assertEquals(0x2019, PtpConstants.DEVICE_BUSY)
        assertEquals(0x201E, PtpConstants.SESSION_ALREADY_OPEN)
        assertEquals(0xFFFFFFFFL, PtpConstants.SIZE_UNKNOWN)
        assertEquals("192.168.1.1", PtpConstants.CAMERA_IP)
        assertEquals(15740, PtpConstants.PTP_PORT)
    }

    @Test
    fun formatMappingsAndFallbackRemainStable() {
        assertEquals(
            listOf(
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
                0xB809 to ".arw",
            ),
            PtpConstants.FORMAT_EXT.toList(),
        )
        assertEquals(".jpg", PtpConstants.getExt(0x3801))
        assertEquals(".nef", PtpConstants.getExt(0xB101))
        assertEquals(".mov", PtpConstants.getExt(0x300D))
        assertEquals(".mp4", PtpConstants.getExt(0x300E))
        assertEquals(".bin", PtpConstants.getExt(0xFFFF))
    }
}
