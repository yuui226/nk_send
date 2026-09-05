package com.ztransfer.viewmodel

import com.ztransfer.protocol.CameraFileInfo
import com.ztransfer.protocol.PtpConstants
import kotlin.test.*

class NativeOriginalFileIndexTest {
    private fun file(name: String = "DSC_0001.JPG", size: Long = 3) = CameraFileInfo(1, size, name, null)
    private fun full(revision: Long = 1) = NativeOriginalIndexUpdate(revision, -1, true)

    @Test fun copySuffixCaseAndSizeUseTheExistingSharedLookupKernel() {
        val index = NativeOriginalFileIndex()
        val input = full().also { assertTrue(it.add("dsc_0001 (2).jpg", 3, null, "local-copy")) }
        assertTrue(index.apply(input))
        assertTrue(index.contains(file(), null))
        assertFalse(index.contains(file(size = 4), null))
        assertTrue(index.contains(file(size = PtpConstants.SIZE_UNKNOWN), null))
        assertEquals("local-copy", index.localLocator(file(), null))
        assertFalse(index.contains(file("DSC_0002.JPG"), null))
    }

    @Test fun rootAndDateBucketsNeverLeakIntoEachOther() {
        val index = NativeOriginalFileIndex()
        val input = full().also {
            it.add("DSC_0001.JPG", 3, "ZT2026-09-05", "dated")
            it.add("DSC_0002.JPG", 3, null, "root")
        }
        assertTrue(index.apply(input))
        assertFalse(index.contains(file(), null))
        assertTrue(index.contains(file(), "zt2026-09-05"))
        assertFalse(index.contains(file(), "ZT2026-09-04"))
        assertFalse(index.contains(file("DSC_0002.JPG"), "ZT2026-09-05"))
    }

    @Test fun deltasRequireThePublishedBaseAndRejectInvalidBatchesAtomically() {
        val index = NativeOriginalFileIndex()
        assertFalse(index.apply(NativeOriginalIndexUpdate(1, 0, false)))
        assertTrue(index.apply(full()))
        val delta = NativeOriginalIndexUpdate(2, 1, false).also { it.add("DSC_0001.JPG", 3, null, "local") }
        assertTrue(index.apply(delta))
        assertFalse(index.apply(delta))
        assertFalse(index.apply(full(1)))
        assertTrue(index.apply(NativeOriginalIndexUpdate(2, 2, false))) // A no-change acknowledgement is safe.
        assertFalse(index.apply(NativeOriginalIndexUpdate(2, 2, false).also {
            it.add("UNVERSIONED.JPG", 3, null, "unversioned")
        }))
        val invalid = NativeOriginalIndexUpdate(3, 2, false)
        assertTrue(invalid.add("DSC_0002.JPG", 3, null, "second"))
        assertFalse(invalid.add("bad/name.JPG", 3, null, "bad"))
        assertFalse(index.apply(invalid))
        assertEquals(2L, index.revision)
        assertFalse(index.contains(file("DSC_0002.JPG"), null))
        assertTrue(index.contains(file(), null))
    }

    @Test fun completeRescanCanReflectDeletionAndBuilderMutationIsIsolated() {
        val index = NativeOriginalFileIndex()
        val initial = full().also { it.add("DSC_0001.JPG", 3, null, "one") }
        assertTrue(index.apply(initial))
        initial.add("DSC_0002.JPG", 3, null, "late")
        assertFalse(index.apply(initial)) // Replaying a mutated builder cannot smuggle data under the same revision.
        assertFalse(index.contains(file("DSC_0002.JPG"), null))
        assertTrue(index.apply(full(2)))
        assertTrue(index.hasSnapshot)
        assertFalse(index.contains(file(), null))
    }

    @Test fun dateFolderRecognitionPreservesAndroidShapeOnlyBehavior() {
        assertTrue(NativeOriginalIndexPolicy.isDateFolder("ZT2026-99-99"))
        assertFalse(NativeOriginalIndexPolicy.isDateFolder("zt2026-09-05"))
        assertFalse(NativeOriginalIndexPolicy.isDateFolder("frames"))
        assertFalse(NativeOriginalIndexPolicy.isDateFolder("ZT2026-9-05"))
        assertFalse(full().add("X.JPG", 3, "frames", "x"))
        assertFalse(full().add("X.JPG", -1, null, "x"))
        assertFalse(full().add("X.JPG", 3, null, ""))
        assertTrue(NativeOriginalIndexPolicy.isPartName(".nkpart_123_photo.JPG"))
        assertFalse(NativeOriginalIndexPolicy.isPartName(".hidden.JPG"))
    }
}
