package com.ztransfer.ui

import com.ztransfer.catalog.*
import com.ztransfer.protocol.CameraFileInfo
import com.ztransfer.ui.screen.SharedPhotoFilterCriteria
import kotlin.test.*

class NativeFilesBrowsePolicyTest {
    private val files = listOf(
        CameraFileInfo(3, 3, "DSC_0003.JPG", "20260905T120003", false, setOf(0x20001)),
        CameraFileInfo(1, 1, "DSC_0001.JPG", "20260905T120001", true, setOf(0x10001, 0x20001)),
        CameraFileInfo(4, 4, "UNKNOWN.JPG", null, true, setOf(0x20001)),
        CameraFileInfo(2, 2, "RAW.NEF", "20260904T120002", true, setOf(0x10001)),
        CameraFileInfo(5, 5, "MOVIE.MOV", "20260903T120000", false, emptySet()),
    )
    private val stores = listOf(0x10001, 0x20001)

    @Test fun everyCombinedFilterMatchesIndependentFixtureExpectationsAndPreservesOrder() {
        assertEquals(listOf(3, 1, 4), nativeFilteredCameraFiles(files, stores,
            SharedPhotoFilterCriteria(extensions = setOf(".jpg")), emptySet(), emptySet()).map { it.handle })
        for (extensions in listOf(null, setOf(".jpg"), setOf(".nef"), emptySet<String>())) {
            for (mask in 0..7) for (slot in listOf(null, 1, 2)) for (day in listOf(false, true)) {
                val criteria = SharedPhotoFilterCriteria(
                    extensions = extensions, protectedOnly = mask and 1 != 0, burstOnly = mask and 2 != 0,
                    untransferredOnly = mask and 4 != 0, storageSlot = slot,
                    dateRange = if (day) CaptureDayRange.between(20260905, 20260905) else null,
                )
                val actual = nativeFilteredCameraFiles(files, stores, criteria, setOf(1, 3), setOf(1)).map { it.handle }
                val expected = files.filter { file ->
                    (extensions == null || file.extension in extensions) &&
                        (mask and 1 == 0 || file.handle in setOf(1, 2, 4)) &&
                        (mask and 2 == 0 || file.handle in setOf(1, 3)) &&
                        (mask and 4 == 0 || file.handle != 1) &&
                        (slot == null || (slot == 1 && file.handle in setOf(1, 2)) || (slot == 2 && file.handle in setOf(1, 3, 4))) &&
                        (!day || file.handle in setOf(1, 3))
                }.map { it.handle }
                assertEquals(expected, actual, "ext=$extensions mask=$mask slot=$slot day=$day")
            }
        }
    }

    @Test fun emptySecondCardRemainsARealFilterRatherThanFallingBackToAllFiles() {
        val oneCardFiles = files.filter { it.handle == 2 }
        assertEquals(listOf(1, 2), storageFilterSlots(storageIdsBySlot(stores).keys))
        assertTrue(nativeFilteredCameraFiles(oneCardFiles, stores, SharedPhotoFilterCriteria(storageSlot = 2), emptySet(), emptySet()).isEmpty())
        assertTrue(nativeFilteredCameraFiles(files, stores, SharedPhotoFilterCriteria(storageSlot = 9), emptySet(), emptySet()).isEmpty())
        assertEquals(listOf(2), nativeFilteredCameraFiles(oneCardFiles, stores, SharedPhotoFilterCriteria(storageSlot = 1), emptySet(), emptySet()).map { it.handle })
    }

    @Test fun burstMembershipComesFromTheFullCatalogEvenWhenFiltersLeaveOneMember() {
        val burst = (1..3).map { CameraFileInfo(it, 3, "DSC_000$it.JPG", "20260905T12000$it", it == 1, setOf(0x10001)) }
        val handles = detectCameraBurstGroups(burst).flatMap { it.files }.mapTo(HashSet()) { it.handle }
        val filtered = nativeFilteredCameraFiles(burst, stores, SharedPhotoFilterCriteria(protectedOnly = true, burstOnly = true), handles, emptySet())
        assertEquals(listOf(1), filtered.map { it.handle })
        assertTrue(detectCameraBurstGroups(filtered).isEmpty()) // Re-detecting only filtered rows would incorrectly hide it.
    }
}
