package com.ztransfer.protocol

import org.junit.Assert.*
import org.junit.Test

class PhotoMetadataIdentityTest {
    @Test fun reconnectedHandleMustMatchTheOriginalFile() {
        val file = NikonCamera.FileInfo(10, 12345, "DSC_0001.JPG", "20260929T180000")
        assertTrue(samePhotoMetadataSource(file, file.copy()))
        assertFalse(samePhotoMetadataSource(file, file.copy(fileName = "DSC_0002.JPG")))
        assertFalse(samePhotoMetadataSource(file, file.copy(size = 12346)))
        assertFalse(samePhotoMetadataSource(file, file.copy(captureDate = "20260930T180000")))
        assertFalse(samePhotoMetadataSource(file, null))
        assertFalse(samePhotoMetadataSource(file.copy(captureDate = null), file.copy(captureDate = null)))
    }

    @Test fun knownBodyCanReuseMetadataAcrossConnections() {
        val body = "Nikon\u0000Z 30\u0000serial-123"
        assertEquals(scopedPhotoMetadataIdentity(body, "first"),
            scopedPhotoMetadataIdentity(body, "second"))
    }

    @Test fun unidentifiedBodiesOfTheSameModelCannotShareMetadata() {
        val model = "Nikon\u0000Z 30\u0000unknown-device"
        assertNotEquals(scopedPhotoMetadataIdentity(model, "first"),
            scopedPhotoMetadataIdentity(model, "second"))
        assertEquals(scopedPhotoMetadataIdentity(model, "first"),
            scopedPhotoMetadataIdentity(model, "first"))
    }
}
