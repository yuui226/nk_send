package com.ztransfer.catalog

import kotlin.test.Test
import kotlin.test.assertEquals

class FileScanHandlePolicyTest {
    private val orders = listOf(
        StorageHandleOrder(0x00010001, listOf(105, 103, 101)),
        StorageHandleOrder(0x00020001, listOf(104, 102)),
    )

    @Test
    fun totalCountIncludesEveryStorageOrder() {
        assertEquals(5, totalStorageHandleCount(orders))
    }

    @Test
    fun remainingHandlesPreserveStorageAndCameraOrder() {
        assertEquals(
            listOf(
                StorageHandleOrder(0x00010001, listOf(101)),
                StorageHandleOrder(0x00020001, listOf(104, 102)),
            ),
            remainingStorageHandleOrders(orders, skippedHandles = setOf(105, 103)),
        )
    }
}
