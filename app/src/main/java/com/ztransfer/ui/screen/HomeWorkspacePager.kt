package com.ztransfer.ui.screen

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.pager.PagerDefaults
import androidx.compose.foundation.pager.VerticalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Modifier
import com.ztransfer.viewmodel.CameraViewModel
import com.ztransfer.viewmodel.TransferViewModel
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch

private const val CONNECTION_PAGE = 0
private const val LOCAL_EFFECTS_PAGE = 1
internal const val WORKSPACE_ENTRY_SNAP_THRESHOLD = 0.50f
internal const val WORKSPACE_RETURN_SNAP_THRESHOLD = 0.06f

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
    val cameraState by cameraViewModel.state.collectAsState()
    val snapThreshold = if (pagerState.settledPage == LOCAL_EFFECTS_PAGE) {
        WORKSPACE_RETURN_SNAP_THRESHOLD
    } else {
        WORKSPACE_ENTRY_SNAP_THRESHOLD
    }
    val pagerFlingBehavior = PagerDefaults.flingBehavior(
        state = pagerState,
        // 返回连接页时，长屏上的拖动距离需要足够轻巧，约一成页面即可确认返回。
        // 反向进入工作台仍保留 50%，避免连接页的小幅纵向误触。
        // 两边的快速轻扫均继续由原生速度阈值判定，不叠加第二套手势。
        snapPositionalThreshold = snapThreshold,
    )

    // 相邻页常驻才能在普通返回连接页时保留原图、效果状态和渲染缓存。
    // 真正进入相机握手（或已连上）时递增代次，key 会一次性销毁整棵工作台组合：
    // rememberCoroutineScope 取消正在进行的解码/导出，DisposableEffect 关闭渲染缓存，Bitmap 引用随之释放。
    var localWorkspaceGeneration by remember { mutableIntStateOf(0) }
    var releasedForCurrentConnection by remember { mutableStateOf(false) }
    val releaseLocalWorkspace = shouldReleaseLocalWorkspace(
        isConnecting = cameraState.isConnecting,
        isConnected = cameraState.isConnectedToCamera,
    )
    LaunchedEffect(releaseLocalWorkspace) {
        if (releaseLocalWorkspace && !releasedForCurrentConnection) {
            localWorkspaceGeneration++
            releasedForCurrentConnection = true
        } else if (!releaseLocalWorkspace) {
            releasedForCurrentConnection = false
        }
    }

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
        // 两页只有一个相邻页；常驻它保留工作台会话，不会扩大到更多离屏页。
        beyondViewportPageCount = 1,
        modifier = Modifier.fillMaxSize(),
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
                    scope.launch { pagerState.animateScrollToPage(LOCAL_EFFECTS_PAGE) }
                },
            )
            LOCAL_EFFECTS_PAGE -> key(localWorkspaceGeneration) {
                LocalPhotoEffectsPage(
                    viewModel = transferViewModel,
                    onNavigateUp = returnToConnectionPage,
                )
            }
        }
    }
}
