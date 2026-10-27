package com.ztransfer.protocol

import org.junit.Assert.assertEquals
import org.junit.Test

class JpegThumbnailFallbackTest {
    @Test fun `normal thumbnail never adds a file read`() {
        assertEquals(0, fallback(PtpConstants.RESPONSE_OK, hasThumbnail = true))
    }

    @Test fun `USB Z30 no-thumbnail response reads only bounded JPEG EXIF`() {
        assertEquals(128 * 1024, fallback(0x2010))
        assertEquals(128 * 1024, fallback(0x2010, fileName = "Z30_0395.jpeg"))
    }

    @Test fun `successful empty thumbnail permits the same bounded fallback`() {
        assertEquals(128 * 1024, fallback(PtpConstants.RESPONSE_OK))
    }

    @Test fun `removed busy or rejected object does not trigger a header read`() {
        listOf(PtpConstants.INVALID_OBJECT_HANDLE, PtpConstants.DEVICE_BUSY, 0x2005).forEach {
            assertEquals(0, fallback(it))
        }
    }

    @Test fun `RAW and movie readers remain unchanged`() {
        listOf("photo.NEF", "photo.NRW", "video.MOV", "video.MP4").forEach {
            assertEquals(0, fallback(0x2010, fileName = it))
        }
        assertEquals(0, jpegThumbnailFallbackHeaderBytes(0x2010, false, null))
    }

    @Test fun `short and invalid file sizes never read past the file or overflow`() {
        assertEquals(127, fallback(0x2010, size = 127))
        assertEquals(0, fallback(0x2010, size = 0))
        assertEquals(0, fallback(0x2010, size = -1))
        assertEquals(128 * 1024, fallback(0x2010, size = Long.MAX_VALUE))
    }

    private fun fallback(
        response: Int,
        hasThumbnail: Boolean = false,
        fileName: String = "Z30_0395.JPG",
        size: Long = 11_262_279,
    ): Int = jpegThumbnailFallbackHeaderBytes(
        response, hasThumbnail,
        NikonCamera.FileInfo(handle = 1, size = size, fileName = fileName, captureDate = null),
    )
}
