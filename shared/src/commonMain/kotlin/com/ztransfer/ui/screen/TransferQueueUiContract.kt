package com.ztransfer.ui.screen

import com.ztransfer.viewmodel.TransferTask

/** Low-frequency page snapshot. Active byte progress stays in its separate flow. */
data class TransferQueueUiState(
    val tasks: List<TransferTask>,
    val isTransferring: Boolean,
    // Retain invalidation when the platform's existing-original index changes in place.
    val existingExportRevision: Long,
)

/** Calls execute on the UI owner. The adapter keeps camera and storage ownership. */
@OptIn(kotlin.experimental.ExperimentalObjCRefinement::class)
@kotlin.native.HiddenFromObjC
class TransferQueueUiActions(
    val removeTask: suspend (Long) -> Boolean,
    val withdrawTask: suspend (Long) -> Unit,
    val retrySingleTask: suspend (Long) -> Unit,
    val retryFailed: suspend (Set<Long>) -> Unit,
    val withdrawPending: suspend () -> Unit,
    val removeCleared: suspend () -> Unit,
    // Read live state AFTER removal, not the composition's pre-animation snapshot.
    val currentTasks: () -> List<TransferTask>,
)

/** Platform-localized text; no Android resources in the shared page. */
data class TransferQueueUiText(
    val removeFromQueue: String,
    val retryFailedDescription: String,
    val retryFailedTitle: String,
    val retry: String,
    val clearQueueDescription: String,
    val clearQueueTitle: String,
    val clearQueueSubtitle: String,
    val clear: String,
    val cancel: String,
)
