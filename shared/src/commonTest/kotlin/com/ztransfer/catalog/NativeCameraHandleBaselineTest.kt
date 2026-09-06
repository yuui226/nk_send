package com.ztransfer.catalog

import kotlin.test.*

class NativeCameraHandleBaselineTest {
    @Test fun publishedHandlesDoNotInventAnEnumerationAndLaterScansReplaceTheBaseline() {
        val baseline = NativeCameraHandleBaseline()
        assertFalse(baseline.hasSnapshot)
        baseline.recordPublished(7)
        assertFalse(baseline.hasSnapshot)
        assertTrue(baseline.shouldResolve(7, emptyList()))
        baseline.acceptEnumeration(intArrayOf(), false)
        assertTrue(baseline.hasSnapshot)
        baseline.recordPublished(7)
        assertFalse(baseline.shouldResolve(7, emptyList()))
        assertEquals(CameraHandleDelta(emptySet(), setOf(7)), baseline.acceptEnumeration(intArrayOf(), true))
        assertTrue(baseline.shouldResolve(7, emptyList()))
    }

    @Test fun resolverAdmissionKeepsKnownRawHandlesAndVisibleHandlesDistinct() {
        val baseline = NativeCameraHandleBaseline()
        baseline.acceptEnumeration(intArrayOf(7), false)
        val visible = com.ztransfer.protocol.CameraFileInfo(8, 1, "OLD.JPG", null, false, emptySet())
        for (handle in listOf(0, -1, 7, 8)) assertFalse(baseline.shouldResolve(handle, listOf(visible)))
        assertTrue(baseline.shouldResolve(Int.MIN_VALUE, listOf(visible)))
        assertTrue(baseline.shouldResolve(9, listOf(visible)))
    }

    @Test fun firstCatalogNeverReportsOldPhotosEvenWhenDetectionIsRequested() {
        val baseline = NativeCameraHandleBaseline()
        assertEquals(CameraHandleDelta(emptySet(), emptySet()), baseline.acceptEnumeration(intArrayOf(7, 8), true))
        assertEquals(CameraHandleDelta(setOf(9), setOf(7)), baseline.acceptEnumeration(intArrayOf(8, 9), true))
    }

    @Test fun emptyCatalogIsARealBaselineAndLaterEmptyCatalogReportsRemovals() {
        val baseline = NativeCameraHandleBaseline()
        baseline.acceptEnumeration(intArrayOf(), true)
        assertEquals(CameraHandleDelta(setOf(7), emptySet()), baseline.acceptEnumeration(intArrayOf(7), true))
        assertEquals(CameraHandleDelta(emptySet(), setOf(7)), baseline.acceptEnumeration(intArrayOf(), true))
        assertEquals(CameraHandleDelta(setOf(7), emptySet()), baseline.acceptEnumeration(intArrayOf(7), true))
    }

    @Test fun disabledDetectionStillAdvancesBaselineAndReportsRemovals() {
        val baseline = NativeCameraHandleBaseline()
        baseline.acceptEnumeration(intArrayOf(1, 2), true)
        assertEquals(CameraHandleDelta(emptySet(), setOf(1)), baseline.acceptEnumeration(intArrayOf(2, 3), false))
        assertEquals(CameraHandleDelta(setOf(4), emptySet()), baseline.acceptEnumeration(intArrayOf(2, 3, 4), true))
    }

    @Test fun rawHandlesAcrossCardsAreDeduplicatedAndCopiedWithoutSignedFiltering() {
        val baseline = NativeCameraHandleBaseline()
        val handles = intArrayOf(0, -1, Int.MIN_VALUE, 7, 7)
        baseline.acceptEnumeration(handles, true)
        handles.fill(99)
        assertEquals(CameraHandleDelta(setOf(8), setOf(Int.MIN_VALUE)),
            baseline.acceptEnumeration(intArrayOf(0, -1, 7, 8, 8), true))
    }

    @Test fun reconnectionUsesANewOwnerNotThePreviousCameraBaseline() {
        val old = NativeCameraHandleBaseline()
        old.acceptEnumeration(intArrayOf(1), true)
        val next = NativeCameraHandleBaseline()
        assertEquals(CameraHandleDelta(emptySet(), emptySet()), next.acceptEnumeration(intArrayOf(2), true))
        assertEquals(CameraHandleDelta(setOf(3), setOf(1)), old.acceptEnumeration(intArrayOf(3), true))
    }

    @Test fun everySmallSnapshotMatchesTheOriginalAndroidSharedDeltaRule() {
        val values = listOf(0, -1, Int.MIN_VALUE, 7, 8)
        fun snapshot(mask: Int) = values.filterIndexed { index, _ -> mask and (1 shl index) != 0 }.toSet()
        for (previous in 0 until 32) for (current in 0 until 32) for (detect in listOf(false, true)) {
            val baseline = NativeCameraHandleBaseline()
            baseline.acceptEnumeration(snapshot(previous).toIntArray(), true)
            val expected = cameraHandleDelta(snapshot(previous), snapshot(current))
            val actual = baseline.acceptEnumeration(snapshot(current).toIntArray(), detect)
            assertEquals(if (detect) expected.added else emptySet(), actual.added)
            assertEquals(expected.removed, actual.removed)
            assertEquals(CameraHandleDelta(emptySet(), emptySet()), baseline.acceptEnumeration(snapshot(current).toIntArray(), true))
        }
    }
}
