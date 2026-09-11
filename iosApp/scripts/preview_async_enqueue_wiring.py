"""Enumerated optional async hook; removing it yields the entire original sync coordinator."""
from transfer_card_extraction import replace_once

REPLACEMENTS = [
    ('    // 预览内主动展开/收起合集时同步底层列表，关闭预览后两处状态一致。',
     '''    // Native queue admission is asynchronous. Null preserves the original synchronous Android path.
    onTransferAsync: (suspend (List<CameraFileInfo>) -> Int)? = null,
    // 预览内主动展开/收起合集时同步底层列表，关闭预览后两处状态一致。'''),
    ('    val currentOnTransferBurst by rememberUpdatedState(onTransferBurst)',
     '''    val currentOnTransferBurst by rememberUpdatedState(onTransferBurst)
    val currentOnTransferAsync by rememberUpdatedState(onTransferAsync)
    val asyncQueueAcceptance = remember(onTransferAsync != null) {
        if (onTransferAsync != null) PreviewQueueAcceptance() else null
    }
    if (asyncQueueAcceptance != null) {
        DisposableEffect(asyncQueueAcceptance) {
            onDispose { asyncQueueAcceptance.close() }
        }
        DisposableEffect(asyncQueueAcceptance, currentItem?.key, closing) {
            onDispose { asyncQueueAcceptance.cancel() }
        }
    }'''),
    ('    fun enqueueFromPreview(file: CameraFileInfo) {',
     '''    fun awaitPreviewQueueAcceptance(
        files: List<CameraFileInfo>, bitmap: ImageBitmap?, rotation: Float,
        burstFiles: List<CameraFileInfo>? = null,
    ) {
        val enqueue = currentOnTransferAsync ?: return
        val gate = asyncQueueAcceptance ?: return
        if (queueAnimating || closing || burstTransitionBusy) return
        val key = previewItems.getOrNull(pagerState.currentPage)?.key ?: return
        // Do not hold an upward drag indefinitely while waiting for the real queue acknowledgement.
        queueGestureActive = false
        settleQueuePhoto()
        gate.request(previewScope, files,
            isCurrent = {
                !closing && !queueAnimating && !burstTransitionBusy &&
                    previewItems.getOrNull(pagerState.currentPage)?.key == key
            },
            enqueue = enqueue,
            onAccepted = {
                // Already confirmed by the real queue, not an optimistic success or a second enqueue.
                startPreviewQueueFlight(bitmap, rotation, burstFiles) { true }
            },
        )
    }

    fun enqueueFromPreview(file: CameraFileInfo) {'''),
    ('''        startPreviewQueueFlight(bitmap, rotationDegrees) {
            currentOnTransfer(file)''',
     '''        if (currentOnTransferAsync != null) {
            awaitPreviewQueueAcceptance(listOf(file), bitmap, rotationDegrees)
            return
        }
        startPreviewQueueFlight(bitmap, rotationDegrees) {
            currentOnTransfer(file)'''),
    ('''        if (collection.files.isEmpty()) return
        startPreviewQueueFlight(''',
     '''        if (collection.files.isEmpty()) return
        if (currentOnTransferAsync != null) {
            awaitPreviewQueueAcceptance(collection.files, null, 0f, collection.files)
            return
        }
        startPreviewQueueFlight('''),
]


def add_async_preview_enqueue(source):
    for before, after in REPLACEMENTS:
        source = replace_once(source, before, after)
    return source


def remove_async_preview_enqueue(source):
    for before, after in reversed(REPLACEMENTS):
        source = replace_once(source, after, before)
    return source
