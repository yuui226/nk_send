package com.ztransfer.catalog

/** Total number of handles captured by one immutable enumeration snapshot. */
fun totalStorageHandleCount(handleOrders: List<StorageHandleOrder>): Int =
    handleOrders.sumOf { it.newestFirstHandles.size }

/** Preserves storage and handle order while removing handles already processed by the caller. */
fun remainingStorageHandleOrders(
    handleOrders: List<StorageHandleOrder>,
    skippedHandles: Set<Int>,
): List<StorageHandleOrder> = handleOrders.map { order ->
    order.copy(
        newestFirstHandles = order.newestFirstHandles.filterNot { it in skippedHandles },
    )
}
