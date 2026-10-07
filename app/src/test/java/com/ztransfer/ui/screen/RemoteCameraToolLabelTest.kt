package com.ztransfer.ui.screen

import com.ztransfer.R
import com.ztransfer.protocol.RemoteCameraTool
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class RemoteCameraToolLabelTest {
    @Test fun reportedNikonOptionsAreNamedAcrossPhotoFallbackAndMovieProperties() {
        val expected = mapOf(
            32784L to R.string.remote_af_single,
            32785L to R.string.remote_af_auto,
            32791L to R.string.remote_af_pinpoint,
            32792L to R.string.remote_af_wide_s,
            32793L to R.string.remote_af_wide_l,
            32794L to R.string.remote_af_wide_people,
            32795L to R.string.remote_af_wide_animals,
            32800L to R.string.remote_af_auto_people,
            32801L to R.string.remote_af_auto_animals,
        )
        for (prop in listOf(0x501C, 0xD05D, 0xD1F8)) {
            for ((value, resource) in expected) {
                assertEquals("prop=$prop value=$value", resource,
                    cameraToolLabelResource(RemoteCameraTool.FOCUS_AREA, prop, value))
            }
        }
    }
    @Test fun unrelatedOrUnknownCodesKeepTheirFallback() {
        assertNull(cameraToolLabelResource(RemoteCameraTool.FOCUS_AREA, 0xD05D, 2L))
        assertNull(cameraToolLabelResource(RemoteCameraTool.FOCUS_AREA, 0x1234, 32784L))
        assertNull(cameraToolLabelResource(RemoteCameraTool.FOCUS_AREA, 0x501C, 99999L))
    }

    @Test fun z30PhotoFocusAreaShortDynamicValuesAreNamed() {
        assertEquals(R.string.remote_af_dynamic_s,
            cameraToolLabelResource(RemoteCameraTool.FOCUS_AREA, 0xD05D, 2L, "Z 30", 0x0002))
        assertEquals(R.string.remote_af_dynamic_m,
            cameraToolLabelResource(RemoteCameraTool.FOCUS_AREA, 0xD05D, 0x8013L, "Z 30", 0x0002))
        assertEquals(R.string.remote_af_dynamic_l,
            cameraToolLabelResource(RemoteCameraTool.FOCUS_AREA, 0xD05D, 0x8014L, "Z 30", 0x0002))
    }

    @Test fun modelSpecificPointCountsDoNotLeakToOtherBodies() {
        fun label(model: String?, value: Long) =
            cameraToolLabelResource(RemoteCameraTool.FOCUS_AREA, 0x501C, value, model)
        assertEquals(R.string.remote_af_dynamic_21, label("NIKON D7100", 0x8013))
        assertEquals(R.string.remote_af_dynamic_72, label("D850", 0x8013))
        assertEquals(R.string.remote_af_dynamic_9, label("D7100", 2))
        assertEquals(R.string.remote_af_dynamic_25, label("D850", 2))
        assertNull(label("Z 8", 0x8013))
        assertNull(label(null, 0x8012))
        assertNull(label("Z 8", 0x801C))
        assertNull(label("Z 8", 0x801D))
    }

    @Test fun legacyLiveViewRequiresTheCorrectPropertyAndByteType() {
        fun label(prop: Int, type: Int) =
            cameraToolLabelResource(RemoteCameraTool.FOCUS_AREA, prop, 2, "D850", type)
        assertEquals(R.string.remote_af_normal, label(0xD05D, 0x0002))
        assertEquals(R.string.remote_af_normal, label(0xD05D, 0x0001))
        assertNull(label(0xD05D, 0x0004))
        assertNull(label(0xD1F8, 0x0002))
    }
}
