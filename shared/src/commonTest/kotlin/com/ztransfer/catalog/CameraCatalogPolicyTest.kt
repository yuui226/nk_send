package com.ztransfer.catalog

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertSame

class CameraCatalogPolicyTest {
    @Test
    fun apAndStaStorageFilteringRetainsTheExistingRules() {
        assertEquals(
            listOf(0x00010001),
            usableStorageIds(listOf(0x00010000, 0x00010001), isStaConnection = false),
        )
        assertEquals(
            listOf(0x00010000),
            usableStorageIds(listOf(0, -1, 0x00010000, 0x00010000), isStaConnection = true),
        )
        assertEquals(0x00010001, objectHandleQueryStorageId(0x00010001, false))
        assertEquals(-1, objectHandleQueryStorageId(0x00010000, true))
    }

    @Test
    fun handleDeltaReportsAdditionsAndRemovalsIndependently() {
        assertEquals(
            CameraHandleDelta(added = setOf(12), removed = emptySet()),
            cameraHandleDelta(setOf(10, 11), setOf(10, 11, 12)),
        )
        assertEquals(
            CameraHandleDelta(added = setOf(12), removed = setOf(11)),
            cameraHandleDelta(setOf(10, 11), setOf(10, 12)),
        )
        assertEquals(
            CameraHandleDelta(added = setOf(1), removed = emptySet()),
            cameraHandleDelta(emptySet(), setOf(1)),
        )
        assertEquals(
            CameraHandleDelta(added = emptySet(), removed = setOf(1)),
            cameraHandleDelta(setOf(1), emptySet()),
        )
    }

    @Test
    fun logicalIdentityAndMembershipRemainStable() {
        assertEquals(
            "DSC_0001.JPG|1024|null",
            cameraFileLogicalIdentity("DSC_0001.JPG", 1024L, null),
        )
        val existing = linkedSetOf(0x00010001)
        assertEquals(
            setOf(0x00010001, 0x00020001),
            mergeStorageIds(existing, setOf(0x00020001)),
        )
        assertSame(existing, mergeStorageIds(existing, setOf(0x00010001)))
    }

    @Test
    fun fileHeadPreferenceReleasesMissingDatesAndKeepsTiesStable() {
        assertEquals(true, isCameraFileHeadPreferred(null, "20260807T090000"))
        assertEquals(false, isCameraFileHeadPreferred("20260807T090000", null))
        assertEquals(false, isCameraFileHeadPreferred(null, null))
        assertEquals(false, isCameraFileHeadPreferred("20260807T090000", "20260807T090000"))
        assertEquals(true, isCameraFileHeadPreferred("20260808T090000", "20260807T090000"))
        // Existing behavior is lexical comparison, even for malformed date strings.
        assertEquals(true, isCameraFileHeadPreferred("invalid", "20260807T090000"))
    }

    @Test
    fun standardAndFallbackStorageSlotsRemainStable() {
        assertEquals(
            mapOf(1 to setOf(0x00010001), 2 to setOf(0x00020001)),
            storageIdsBySlot(listOf(0x00020001, 0x00010001)),
        )
        assertEquals(
            mapOf(2 to setOf(0x00020001)),
            storageIdsBySlot(listOf(0x00020001)),
        )
        assertEquals(
            mapOf(1 to setOf(0x00030001), 2 to setOf(0x00040001)),
            storageIdsBySlot(listOf(0x00040001, 0x00030001)),
        )
        assertEquals(
            mapOf(1 to setOf(0x00010001, 0x00010002), 2 to setOf(0x00020001)),
            storageIdsBySlot(listOf(0x00010002, 0x00020001, 0x00010001)),
        )
        assertEquals(
            mapOf(1 to setOf(1), 2 to setOf(2)),
            storageIdsBySlot(listOf(2, 1)),
        )
        assertEquals(
            mapOf(1 to setOf(0x00010001), 2 to setOf(0x00020001)),
            storageIdsBySlot(listOf(0x00010001, 0x00020001, 0x00030001)),
        )
    }

    @Test
    fun handlesReversePerCardWithoutNumericSortingAndDeduplicateAcrossCards() {
        val jpgOld = 0x29195C4B
        val rawOld = 0x09195C4B
        val movie = 0x61195C4C
        val jpgNew = 0x29195C4D
        val rawNew = 0x09195C4D

        assertEquals(
            listOf(
                StorageHandleOrder(
                    0x00010001,
                    listOf(rawNew, jpgNew, movie, rawOld, jpgOld),
                ),
            ),
            newestFirstHandleOrders(
                listOf(
                    StorageHandleBatch(
                        0x00010001,
                        listOf(jpgOld, rawOld, movie, jpgNew, rawNew),
                    ),
                ),
            ),
        )
        assertEquals(
            listOf(
                StorageHandleOrder(1, listOf(3, 2, 1)),
                StorageHandleOrder(2, listOf(5, 4)),
            ),
            newestFirstHandleOrders(
                listOf(
                    StorageHandleBatch(1, listOf(1, 2, 3)),
                    StorageHandleBatch(2, listOf(2, 4, 5)),
                ),
            ),
        )
    }

    @Test
    fun directStaDisjointHandlesPreserveExactMembership() {
        val layout = analyzeStaDirectStorageLayout(
            listOf(
                StorageHandleBatch(0x00010001, listOf(11, 12)),
                StorageHandleBatch(0x00020001, listOf(21, 22)),
            ),
        )

        assertEquals(setOf(0x00010001), layout.storageIdsByHandle[11])
        assertEquals(setOf(0x00020001), layout.storageIdsByHandle[22])
        assertEquals(listOf(0x00010001, 0x00020001), layout.filterStorageIds)
        assertEquals(0, layout.crossSlotOverlapCount)
    }

    @Test
    fun crossSlotOverlapDisablesFilteringButSameCardPartitionsRemainReliable() {
        val aggregate = analyzeStaDirectStorageLayout(
            listOf(
                StorageHandleBatch(0x00010001, listOf(11, 12, 13)),
                StorageHandleBatch(0x00020001, listOf(11, 12, 13)),
            ),
        )
        assertEquals(emptyMap(), aggregate.storageIdsByHandle)
        assertEquals(emptyList(), aggregate.filterStorageIds)
        assertEquals(3, aggregate.crossSlotOverlapCount)

        val partitions = analyzeStaDirectStorageLayout(
            listOf(
                StorageHandleBatch(0x00010001, listOf(11, 12)),
                StorageHandleBatch(0x00010002, listOf(12, 13)),
            ),
        )
        assertEquals(setOf(0x00010001, 0x00010002), partitions.storageIdsByHandle[12])
        assertEquals(listOf(0x00010001, 0x00010002), partitions.filterStorageIds)
        assertEquals(0, partitions.crossSlotOverlapCount)
    }
}
