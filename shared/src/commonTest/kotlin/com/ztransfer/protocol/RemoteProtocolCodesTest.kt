package com.ztransfer.protocol

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals

class RemoteProtocolCodesTest {
    @Test
    fun remoteOperationCodesRemainStable() {
        assertContentEquals(
            intArrayOf(
                0x1014, 0x1015, 0x1016,
                0x9201, 0x9202, 0x9203, 0x9428,
                0x9204, 0x9205, 0x90C1, 0x9424, 0x9425,
                0x9207, 0x90C0, 0x90C2, 0x90C7, 0x90C8,
                0x90CA, 0x9439, 0x941C, 0x941E, 0x943B,
                0x920A, 0x920B, 0x9435,
            ),
            intArrayOf(
                Lab.GET_DEVICE_PROP_DESC,
                Lab.GET_DEVICE_PROP_VALUE,
                Lab.SET_DEVICE_PROP_VALUE,
                Lab.NK_START_LIVE_VIEW,
                Lab.NK_END_LIVE_VIEW,
                Lab.NK_GET_LIVE_VIEW_IMG,
                Lab.NK_GET_LIVE_VIEW_IMG_EX,
                Lab.NK_MF_DRIVE,
                Lab.NK_CHANGE_AF_AREA,
                Lab.NK_AF_DRIVE,
                Lab.NK_START_TRACKING,
                Lab.NK_END_TRACKING,
                Lab.NK_CAPTURE_REC_IN_MEDIA,
                Lab.NK_CAPTURE_REC_IN_SDRAM,
                Lab.NK_SET_CONTROL_MODE,
                Lab.NK_GET_EVENT,
                Lab.NK_DEVICE_READY,
                Lab.NK_GET_VENDOR_PROP_CODES,
                Lab.NK_GET_VENDOR_CODES,
                Lab.NK_GET_EVENT_EX,
                Lab.NK_POWER_ZOOM_BY_FOCAL_LENGTH,
                Lab.NK_GET_DEVICE_PROP_VALUE_EX,
                Lab.NK_START_MOVIE_REC,
                Lab.NK_END_MOVIE_REC,
                Lab.NK_CHANGE_APP_MODE,
            ),
        )
    }

    @Test
    fun remoteEventAndResponseCodesRemainStable() {
        assertContentEquals(
            intArrayOf(0x4002, 0x4003, 0x4006, 0x400D, 0xC101, 0xC105, 0xC108, 0xC10A),
            intArrayOf(
                Lab.EVT_OBJECT_ADDED,
                Lab.EVT_OBJECT_REMOVED,
                Lab.EVT_DEVICE_PROP_CHANGED,
                Lab.EVT_CAPTURE_COMPLETE,
                Lab.EVT_OBJECT_ADDED_SDRAM,
                Lab.EVT_NK_MOVIE_REC_INTERRUPTED,
                Lab.EVT_NK_MOVIE_REC_COMPLETE,
                Lab.EVT_NK_MOVIE_REC_STARTED,
            ),
        )
        assertContentEquals(
            intArrayOf(0x2001, 0x200F, 0x2019, 0xA002, 0xA004, 0xA00B),
            intArrayOf(
                Lab.OK,
                Lab.ACCESS_DENIED,
                Lab.DEVICE_BUSY,
                Lab.NK_OUT_OF_FOCUS,
                Lab.NK_INVALID_STATUS,
                Lab.NK_NOT_LIVE_VIEW,
            ),
        )
        assertEquals(PtpConstants.RESPONSE_OK, Lab.OK)
        assertEquals(PtpConstants.DEVICE_BUSY, Lab.DEVICE_BUSY)
    }

    @Test
    fun remotePropertyCodesAndSurveyOrderRemainStable() {
        assertEquals(0x5001, Lab.PROP_BATTERY_LEVEL)
        assertEquals(0xD1A2, Lab.PROP_NK_LV_STATUS)
        assertEquals(0xD1A3, Lab.PROP_NK_LV_IMAGE_ZOOM_RATIO)
        assertEquals(0xD1A4, Lab.PROP_NK_LV_PROHIBIT)
        assertEquals(0xD1A6, Lab.PROP_NK_LV_SELECTOR)
        assertEquals(0xD0A4, Lab.PROP_NK_MOV_PROHIBIT)
        assertEquals(0xD1F0, Lab.PROP_NK_APPLICATION_MODE)
        assertEquals(0x1D033, Lab.PROP_NK_HI_RES_ZOOM)
        assertEquals(
            listOf(
                Lab.PROP_NK_LV_IMAGE_ZOOM_RATIO,
                Lab.PROP_NK_LV_ZOOM_AREA,
                Lab.PROP_DIGITAL_ZOOM,
                Lab.PROP_NK_HI_RES_ZOOM,
            ),
            Lab.DIGITAL_ZOOM_PROPS.keys.toList(),
        )
        assertEquals("GetLiveViewImgEx", Lab.INTEREST_OPS[Lab.NK_GET_LIVE_VIEW_IMG_EX])
        assertEquals("StartMovieRec", Lab.INTEREST_OPS[Lab.NK_START_MOVIE_REC])
        assertEquals("NikonHiResZoom(ext32)", Lab.INTEREST_PROPS[Lab.PROP_NK_HI_RES_ZOOM])
        assertEquals("MovieExpComp", Lab.INTEREST_PROPS[Lab.PROP_NK_MOVIE_EXP_COMP])
    }
}
