package com.ztransfer.catalog

import kotlin.test.Test
import kotlin.test.assertEquals

class CameraFileNamePolicyTest {
    @Test
    fun extensionIsLowercaseAndIncludesTheLastDot() {
        assertEquals(".jpg", cameraFileExtension("DSC_0001.JPG"))
        assertEquals(".nef", cameraFileExtension("archive.photo.NEF"))
        assertEquals("", cameraFileExtension("README"))
    }

    @Test
    fun existingLeadingAndTrailingDotBehaviorIsPreserved() {
        assertEquals(".jpg", cameraFileExtension(".JPG"))
        assertEquals(".", cameraFileExtension("DSC_0001."))
        assertEquals("", cameraFileExtension(""))
    }
}
