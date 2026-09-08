package com.ztransfer.catalog

import com.ztransfer.protocol.CameraFileInfo
import com.ztransfer.protocol.PtpObjectInfo
import com.ztransfer.viewmodel.logicalIdentity
import com.ztransfer.viewmodel.mergeStorageMembership

/**
 * Single-owner native adapter for the existing normal AP/STA catalog rules. The platform supplies
 * successful handle snapshots and ObjectInfo in requested order. No IO, implicit retries, locale
 * changes or STA-direct inference here. Incomplete identities remain visible but mark the scan
 * incomplete, just like Android; callers must not use them as durable cache identities.
 */
class NativeCameraCatalogScan(rawStorageIds: IntArray, private val stationMode: Boolean) {
    private val stores = usableStorageIds(rawStorageIds.toList(), stationMode)
    private val batches = arrayOfNulls<StorageHandleBatch>(stores.size)
    private var orders: List<StorageHandleOrder>? = null
    private var positions = IntArray(stores.size)
    private var heads = arrayOfNulls<CameraFileInfo>(stores.size)
    private val rows = ArrayList<CameraFileInfo>()
    private val indices = HashMap<String, Int>()
    private val objectInfos = HashMap<Int, PtpObjectInfo>()
    private val indexedHandles = ArrayList<Int>()
    private var direct = false
    private var directLayout: StaDirectStorageLayout? = null
    /** Opt-in before enumeration only; the existing AP/standard STA constructor is unchanged. */
    fun enableDirectObjectReads(): Boolean {
        if (!stationMode || orders != null || batches.any { it != null }) return false
        direct = true
        return true
    }
    fun filterStorageIds(): IntArray = (directLayout?.filterStorageIds ?: stores).toIntArray()
    fun directReadStorageId(handle: Int): Int = directLayout?.storageIdsByHandle?.get(handle)?.firstOrNull() ?: 0
    var metadataComplete: Boolean = true
        private set
    val storageCount: Int get() = stores.size
    val rowCount: Int get() = rows.size
    val totalHandles: Int get() = orders?.let(::totalStorageHandleCount) ?: 0
    val processedHandles: Int get() = positions.sum()
    fun storageId(index: Int): Int = stores.getOrElse(index) { 0 }
    fun queryStorageId(index: Int): Int = objectHandleQueryStorageId(storageId(index), stationMode)
    fun fileAt(index: Int): CameraFileInfo? = rows.getOrNull(index)
    fun objectInfo(handle: Int): PtpObjectInfo? = objectInfos[handle]
    /** Includes hidden backup aliases, in first accepted metadata order; indexed access is O(1). */
    val indexedObjectCount: Int get() = indexedHandles.size
    fun indexedObjectInfoAt(index: Int): PtpObjectInfo? = indexedHandles.getOrNull(index)?.let(objectInfos::get)

    fun addHandles(index: Int, handles: IntArray): Boolean {
        if (orders != null || index !in batches.indices || batches[index] != null) return false
        batches[index] = StorageHandleBatch(stores[index], handles.toList())
        return true
    }

    fun begin(): Boolean {
        if (orders != null || batches.any { it == null }) return false
        if (direct) directLayout = analyzeStaDirectStorageLayout(batches.filterNotNull())
        val seen = mutableSetOf<Int>()
        val inputs = if (direct) batches.filterNotNull().map { batch ->
            batch.copy(handles = batch.handles.filter(seen::add))
        } else batches.filterNotNull()
        orders = newestFirstHandleOrders(inputs)
        return true
    }

    /** Fill each missing card head before selecting the next visible row. -1 means no read needed. */
    fun nextReadStorageIndex(): Int {
        val current = orders ?: return -1
        return current.indices.firstOrNull { heads[it] == null && positions[it] < current[it].newestFirstHandles.size } ?: -1
    }

    fun nextReadHandle(): Int? {
        val index = nextReadStorageIndex()
        return orders?.getOrNull(index)?.newestFirstHandles?.getOrNull(positions[index])
    }

    /** Null denotes an object-level failure, NOT an empty successful catalog. */
    fun accept(handle: Int, info: PtpObjectInfo?): Boolean {
        val index = nextReadStorageIndex()
        if (index < 0 || nextReadHandle() != handle || (info != null && info.handle != handle)) return false
        positions[index]++
        if (info == null) { metadataComplete = false; return true }
        if (info.isAssociation) return true
        val name = info.fileName ?: run { metadataComplete = false; return true }
        if (!objectInfos.containsKey(handle)) indexedHandles += handle
        objectInfos[handle] = info
        metadataComplete = metadataComplete && info.identityComplete
        heads[index] = CameraFileInfo(handle, info.size, name, info.captureDate, info.isProtected,
            if (direct) directLayout?.storageIdsByHandle?.get(handle).orEmpty()
            else if (info.storageId == 0 || info.storageId == -1) emptySet() else setOf(info.storageId))
        return true
    }

    fun publishNext(): Boolean {
        if (orders == null || nextReadStorageIndex() >= 0) return false
        val selected = selectNewestCameraFileHeadIndex(heads.toList()) ?: return false
        val file = heads[selected] ?: return false
        heads[selected] = null
        val identity = file.logicalIdentity()
        val existing = indices[identity]
        if (existing == null) { indices[identity] = rows.size; rows += file }
        else { rows[existing] = mergeStorageMembership(rows[existing], file) }
        return true
    }
}
