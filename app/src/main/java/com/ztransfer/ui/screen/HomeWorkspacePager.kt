package com.ztransfer.ui.screen

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.pager.PagerDefaults
import androidx.compose.foundation.pager.VerticalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.unit.Velocity
import com.ztransfer.gps.NikonGpsRuntime
import com.ztransfer.viewmodel.CameraViewModel
import com.ztransfer.viewmodel.TransferViewModel
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlin.math.abs

private const val CONNECTION_PAGE = 0
private const val LOCAL_EFFECTS_PAGE = 1
internal const val WORKSPACE_ENTRY_SNAP_THRESHOLD = 0.50f
internal const val WORKSPACE_RETURN_SNAP_THRESHOLD = 0.10f

private class WorkspaceReturnDragTracker {
    var consumed = false

    fun reset() {
        consumed = false
    }
}

/** GPS blocks entering the local workbench, but never blocks a return to the connection page. */
internal fun workspacePagerUserScrollEnabled(
    gpsEnabled: Boolean,
    currentPage: Int,
): Boolean = !gpsEnabled ||
    currentPage == LOCAL_EFFECTS_PAGE

internal fun shouldPauseConnectionDiscovery(settledPage: Int, targetPage: Int): Boolean =
    settledPage == LOCAL_EFFECTS_PAGE || targetPage == LOCAL_EFFECTS_PAGE

internal fun shouldReleaseLocalWorkspace(
    isConnecting: Boolean,
    isConnected: Boolean,
): Boolean = isConnecting || isConnected

/** Two vertically adjacent home pages: camera connection above, phone-photo processing below. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun HomeWorkspacePager(
    cameraViewModel: CameraViewModel,
    transferViewModel: TransferViewModel,
    onConnectionCelebrationFinished: () -> Unit,
) {
    val pagerState = rememberPagerState(pageCount = { 2 })
    val scope = rememberCoroutineScope()
    // GPS is a camera-sync mode. Observe only its enabled bit so location/altitude updates do not
    // recompose the pager, while still locking the local workbench for the whole active session.
    val gpsEnabled by remember {
        NikonGpsRuntime.state
            .map { state -> state.enabled }
            .distinctUntilChanged()
    }.collectAsState(initial = NikonGpsRuntime.state.value.enabled)
    // 相册扫描会频繁发布 files；主页容器只观察“是否该释放修图工作台”这一位状态。
    val releaseLocalWorkspace by remember(cameraViewModel) {
        cameraViewModel.state
            .map { state ->
                shouldReleaseLocalWorkspace(
                    isConnecting = state.isConnecting,
                    isConnected = state.isConnectedToCamera,
                )
            }
            .distinctUntilChanged()
    }.collectAsState(
        initial = cameraViewModel.state.value.let { state ->
            shouldReleaseLocalWorkspace(
                isConnecting = state.isConnecting,
                isConnected = state.isConnectedToCamera,
            )
        }
    )
    val snapThreshold = if (pagerState.settledPage == LOCAL_EFFECTS_PAGE) {
        WORKSPACE_RETURN_SNAP_THRESHOLD
    } else {
        WORKSPACE_ENTRY_SNAP_THRESHOLD
    }
    val pagerFlingBehavior = PagerDefaults.flingBehavior(
        state = pagerState,
        // 进入工作台保留 50% 阈值；返回连接页放宽到 10%，仍由 Pager 原生动画跟手处理。
        snapPositionalThreshold = snapThreshold,
    )
    val pagerNestedScrollConnection = PagerDefaults.pageNestedScrollConnection(
        state = pagerState,
        orientation = Orientation.Vertical,
    )
    val returnDragTracker = remember { WorkspaceReturnDragTracker() }
    val returnNestedScrollConnection = remember(pagerNestedScrollConnection) {
        object : NestedScrollConnection {
            override fun onPreScroll(
                available: Offset,
                source: NestedScrollSource,
            ): Offset = pagerNestedScrollConnection.onPreScroll(available, source)

            override fun onPostScroll(
                consumed: Offset,
                available: Offset,
                source: NestedScrollSource,
            ): Offset {
                val delegated = pagerNestedScrollConnection.onPostScroll(consumed, available, source)
                if (source != NestedScrollSource.UserInput ||
                    (pagerState.currentPage != LOCAL_EFFECTS_PAGE && !returnDragTracker.consumed)
                ) {
                    if (source == NestedScrollSource.UserInput) returnDragTracker.reset()
                    return delegated
                }
                // The workbench's verticalScroll reaches this callback when it is already at
                // the top. Feed only the unconsumed return delta into the existing Pager state so
                // the page follows the finger instead of jumping at an arbitrary pixel threshold.
                val remainingY = available.y - delegated.y
                if (remainingY <= 0f) {
                    if (remainingY < 0f) returnDragTracker.reset()
                    return delegated
                }
                val pagerConsumed = -pagerState.dispatchRawDelta(-remainingY)
                if (pagerConsumed <= 0f) return delegated
                returnDragTracker.consumed = true
                return Offset(x = delegated.x, y = delegated.y + pagerConsumed)
            }

            override suspend fun onPreFling(available: Velocity): Velocity =
                pagerNestedScrollConnection.onPreFling(available)

            override suspend fun onPostFling(consumed: Velocity, available: Velocity): Velocity {
                val delegated = pagerNestedScrollConnection.onPostFling(consumed, available)
                if (returnDragTracker.consumed) {
                    val shouldReturn = pagerState.currentPage == CONNECTION_PAGE ||
                        abs(pagerState.currentPageOffsetFraction) >= WORKSPACE_RETURN_SNAP_THRESHOLD ||
                        available.y > 0f
                    scope.launch {
                        pagerState.animateScrollToPage(
                            if (shouldReturn) CONNECTION_PAGE else LOCAL_EFFECTS_PAGE
                        )
                    }
                }
                returnDragTracker.reset()
                return delegated
            }
        }
    }
    // 普通上下翻页时相邻页常驻并保留编辑会话；开始连接后直接替换为空占位，真正释放
    // 解码、导出协程和 Bitmap。不能只更换 key，否则 Pager 会立刻把整张离屏编辑页重建。

    // Pause as soon as a gesture commits toward the lower page, and resume only after the upper
    // page has fully settled. This closes the race in which Wi-Fi connects during the transition.
    LaunchedEffect(pagerState) {
        snapshotFlow {
            shouldPauseConnectionDiscovery(
                settledPage = pagerState.settledPage,
                targetPage = pagerState.targetPage,
            )
        }
            .distinctUntilChanged()
            .collect(cameraViewModel::setConnectionDiscoveryPaused)
    }
    val returnToConnectionPage: () -> Unit = {
        scope.launch { pagerState.animateScrollToPage(CONNECTION_PAGE) }
        Unit
    }
    BackHandler(
        enabled = pagerState.currentPage == LOCAL_EFFECTS_PAGE ||
            pagerState.targetPage == LOCAL_EFFECTS_PAGE,
        onBack = returnToConnectionPage,
    )

    VerticalPager(
        state = pagerState,
        flingBehavior = pagerFlingBehavior,
        userScrollEnabled = workspacePagerUserScrollEnabled(
            gpsEnabled = gpsEnabled,
            currentPage = pagerState.currentPage,
        ),
        // 两页只有一个相邻页；常驻它保留工作台会话，不会扩大到更多离屏页。
        beyondViewportPageCount = 1,
        modifier = Modifier
            .fillMaxSize(),
        pageNestedScrollConnection = returnNestedScrollConnection,
    ) { page ->
        when (page) {
            CONNECTION_PAGE -> HomeScreen(
                viewModel = cameraViewModel,
                transferViewModel = transferViewModel,
                onConnectionCelebrationFinished = {
                    if (pagerState.settledPage == CONNECTION_PAGE &&
                        pagerState.targetPage == CONNECTION_PAGE
                    ) {
                        onConnectionCelebrationFinished()
                    }
                },
                onOpenLocalPhotoEffects = {
                    if (!gpsEnabled) {
                        scope.launch { pagerState.animateScrollToPage(LOCAL_EFFECTS_PAGE) }
                    }
                },
                localPhotoEffectsEnabled = !gpsEnabled,
            )
            LOCAL_EFFECTS_PAGE -> if (releaseLocalWorkspace) {
                Box(Modifier.fillMaxSize())
            } else {
                LocalPhotoEffectsPage(
                    viewModel = transferViewModel,
                    onNavigateUp = returnToConnectionPage,
                )
            }
        }
    }
}
