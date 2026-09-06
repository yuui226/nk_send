package com.ztransfer.catalog

import com.ztransfer.protocol.CameraFileInfo
import com.ztransfer.protocol.PtpObjectInfo
import com.ztransfer.viewmodel.NewCameraObjectPolicy
import com.ztransfer.viewmodel.mergeStorageMembership
import com.ztransfer.viewmodel.reconcilePublishedCameraFiles
import kotlin.test.*

class NativeCameraCatalogReconciliationTest {
    private fun info(handle: Int, name: String = "BACKUP.JPG", store: Int = 0x10001) =
        PtpObjectInfo(handle, store, 0x3801, 10, name, "20260906T120000", false, false, true)
    private fun file(info: PtpObjectInfo) = NewCameraObjectPolicy.publicationFile(info)!!

    @Test fun failedEnumerationIsNotAnEmptyCameraAndInputsAreNotChanged() {
        val info = info(1); val rows = listOf(file(info)); val index = listOf(info)
        assertNull(NativeCameraCatalogReconciliation.reconcile(rows, null, index))
        assertEquals(rows, NativeCameraCatalogReconciliation.reconcile(rows, intArrayOf(1), index))
        assertEquals(emptyList(), NativeCameraCatalogReconciliation.reconcile(rows, intArrayOf(), index))
        assertEquals(1, rows.size); assertSame(info, index.single())
    }

    @Test fun deletedPrimaryPromotesSurvivingAliasAndPrunesOnlyMissingCardMembership() {
        val primary = info(91); val backup = info(7, store = 0x20001); val other = info(8, "OTHER.NEF")
        val merged = mergeStorageMembership(file(primary), file(backup))
        val rows = listOf(merged, file(other)); val index = listOf(primary, backup, other)
        assertEquals(listOf(file(backup), file(other)), NativeCameraCatalogReconciliation.reconcile(rows, intArrayOf(7, 8), index))
        assertEquals(listOf(file(primary), file(other)), NativeCameraCatalogReconciliation.reconcile(rows, intArrayOf(91, 8), index))
        assertEquals(listOf(file(other)), NativeCameraCatalogReconciliation.reconcile(rows, intArrayOf(8), index))
        assertEquals(setOf(0x10001, 0x20001), rows[0].storageIds)
    }

    @Test fun aliasPromotionUsesFirstIndexedSurvivorRatherThanSortingOpaqueHandles() {
        val primary = info(1); val first = info(91, store = 0x20001); val next = info(7, store = 0x30001)
        val rows = listOf(file(primary))
        val result = NativeCameraCatalogReconciliation.reconcile(rows, intArrayOf(7, 91), listOf(primary, first, next))!!
        assertEquals(91, result.single().handle)
        assertEquals(setOf(0x20001, 0x30001), result.single().storageIds)
    }

    @Test fun unresolvedCurrentFilesRemainVisibleAndUnknownNewHandlesAreNotPublished() {
        val old = file(info(1)); val rows = listOf(old)
        val result = NativeCameraCatalogReconciliation.reconcile(rows, intArrayOf(1, 7), emptyList())!!
        assertSame(old, result.single())
        val folder = PtpObjectInfo(7, 1, 0x3001, 0, "DCIM", null, false, true, true)
        val missingName = PtpObjectInfo(8, 1, 0, 0, null, null, false, false, false)
        assertEquals(rows, NativeCameraCatalogReconciliation.reconcile(rows, intArrayOf(1, 7, 8), listOf(folder, missingName)))
    }

    @Test fun combinationsDelegateExactlyToTheUnchangedAndroidPublicationPolicy() {
        val a = info(1); val b = info(91, store = 0x20001); val c = info(7, store = 0x30001)
        val d = info(Int.MIN_VALUE, "OTHER.MOV"); val e = info(5, "OTHER.BIN")
        val choices = listOf(a, b, c, d, e)
        val histories = listOf(emptyList(), listOf(file(a)), listOf(file(a), file(d)),
            listOf(mergeStorageMembership(file(a), file(b)), file(e), file(d)))
        for (mask in 0 until 32) for (order in listOf(choices, choices.reversed(), listOf(d, c, a, e, b))) {
            val handles = choices.filterIndexed { i, _ -> mask and (1 shl i) != 0 }.map { it.handle }.toSet()
            val oldIndex = LinkedHashMap<Int, CameraFileInfo>().apply { order.forEach { put(it.handle, file(it)) } }
            for (rows in histories) {
                assertEquals(reconcilePublishedCameraFiles(rows, handles, oldIndex),
                    NativeCameraCatalogReconciliation.reconcile(rows, handles.toIntArray(), order))
            }
        }
    }
}
