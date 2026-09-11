@file:OptIn(kotlin.experimental.ExperimentalObjCRefinement::class)

package com.ztransfer.ui.screen

import androidx.compose.ui.geometry.Offset
import com.ztransfer.protocol.CameraFileInfo
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

private const val PREVIEW_QUEUE_DIRECTION_RATIO = 1.15f

@kotlin.native.HiddenFromObjC
public enum class PreviewQueueDragDirection { UNDECIDED, UPWARD, REJECTED }

@kotlin.native.HiddenFromObjC
public enum class LocalOriginalPreviewRoute { DIRECT_BITMAP, RAW_EMBEDDED_JPEG, CAMERA_FHD }

@kotlin.native.HiddenFromObjC
public fun <T> isLocalPreviewResolved(
    localSource: T?,
    cachedLocalSource: T?,
): Boolean = localSource != null && cachedLocalSource == localSource

/**
 * 默认缩放下只接管意图明确的上滑。横向或向下移动尽早放行，避免与翻页竞争；
 * 斜向尚未形成稳定方向时继续观察，不在触摸斜率的临界点突然抢手势。
 */
@kotlin.native.HiddenFromObjC
public fun previewQueueDragDirection(
    totalDrag: Offset,
    touchSlop: Float,
): PreviewQueueDragDirection {
    if (totalDrag.getDistance() < touchSlop) return PreviewQueueDragDirection.UNDECIDED
    if (totalDrag.y >= 0f || abs(totalDrag.x) > -totalDrag.y) {
        return PreviewQueueDragDirection.REJECTED
    }
    return if (-totalDrag.y >= abs(totalDrag.x) * PREVIEW_QUEUE_DIRECTION_RATIO) {
        PreviewQueueDragDirection.UPWARD
    } else {
        PreviewQueueDragDirection.UNDECIDED
    }
}

/** 手指越过触发线后增加阻尼，既保持跟手，也避免照片被拖出过远。 */
@kotlin.native.HiddenFromObjC
public fun previewQueueVisualOffset(upwardDistance: Float, triggerDistance: Float): Float {
    if (triggerDistance <= 0f) return 0f
    val distance = upwardDistance.coerceAtLeast(0f)
    val resisted = min(distance, triggerDistance) +
        max(0f, distance - triggerDistance) * 0.22f
    return -min(resisted, triggerDistance * 1.24f)
}

/** 预览分页模型与列表展示模型同构：合集是独立页面，不伪装成其中某张照片。 */
@kotlin.native.HiddenFromObjC
public sealed interface PhotoPreviewItem {
    val key: Any

    data class Photo(
        val file: CameraFileInfo,
        val burstId: String? = null
    ) : PhotoPreviewItem {
        override val key: Any = file.handle
    }

    data class BurstCollection(
        val id: String,
        val files: List<CameraFileInfo>
    ) : PhotoPreviewItem {
        override val key: Any = "preview_burst_$id"
    }
}

/**
 * 固定一次全屏预览会话能够看到的本地原图来源。
 *
 * 传输可能在 overlay 存活期间完成，但此时不能把正在淡入、缩放或绘制的相机 FHD
 * 热替换成完整原图。除了可能重置手势观感，这还会让旧 FHD 与大尺寸本地位图在同一帧
 * 参与纹理上传，造成明显的内存峰值，部分设备会直接崩溃。下次重新打开 overlay 时会
 * 创建新快照，自然获得刚传完的原图。合集成员也必须在打开时一起冻结，否则展开合集
 * 会绕过同一会话规则。
 */
@kotlin.native.HiddenFromObjC
public fun <T> snapshotPreviewSessionSources(
    items: List<PhotoPreviewItem>,
    sourceFor: (CameraFileInfo) -> T?,
): Map<Int, T?> = buildMap {
    items.forEach { item ->
        when (item) {
            is PhotoPreviewItem.Photo -> put(item.file.handle, sourceFor(item.file))
            is PhotoPreviewItem.BurstCollection -> item.files.forEach { file ->
                put(file.handle, sourceFor(file))
            }
        }
    }
}

@kotlin.native.HiddenFromObjC
public fun isPreviewBurstExpanded(
    items: List<PhotoPreviewItem>,
    collectionPage: Int,
    burstId: String
): Boolean =
    (items.getOrNull(collectionPage + 1) as? PhotoPreviewItem.Photo)?.burstId == burstId

@kotlin.native.HiddenFromObjC
public fun expandPreviewBurst(
    items: List<PhotoPreviewItem>,
    collectionPage: Int,
    collection: PhotoPreviewItem.BurstCollection
): List<PhotoPreviewItem> {
    if (isPreviewBurstExpanded(items, collectionPage, collection.id)) return items
    val members = collection.files.map { file ->
        PhotoPreviewItem.Photo(file = file, burstId = collection.id)
    }
    return buildList(items.size + members.size) {
        addAll(items.take(collectionPage + 1))
        addAll(members)
        addAll(items.drop(collectionPage + 1))
    }
}

@kotlin.native.HiddenFromObjC
public fun collapsePreviewBurst(
    items: List<PhotoPreviewItem>,
    burstId: String
): List<PhotoPreviewItem> =
    items.filterNot { it is PhotoPreviewItem.Photo && it.burstId == burstId }

/** 当前页必须是合集之后的真实成员；成员数量和所在序号不会影响返回的合集页。 */
@kotlin.native.HiddenFromObjC
public fun previewBurstCollectionPage(
    items: List<PhotoPreviewItem>,
    memberPage: Int,
): Int? {
    val burstId = (items.getOrNull(memberPage) as? PhotoPreviewItem.Photo)?.burstId
        ?: return null
    val collectionPage = items.indexOfFirst {
        it is PhotoPreviewItem.BurstCollection && it.id == burstId
    }
    return collectionPage.takeIf { it in 0 until memberPage }
}

/**
 * 大图期间默认禁止远程缩略图；只有当前页 FHD 已确认不可用且 EXIF 已收尾时才兜底。
 */
@kotlin.native.HiddenFromObjC
public fun allowPreviewRemoteThumbnailFallback(
    isCurrent: Boolean,
    fhdUnavailable: Boolean,
    exifFinished: Boolean,
): Boolean = isCurrent && fhdUnavailable && exifFinished
