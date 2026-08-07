package com.ztransfer.ui.screen

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.pager.VerticalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Modifier
import com.ztransfer.viewmodel.CameraViewModel
import com.ztransfer.viewmodel.TransferViewModel
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch

private const val CONNECTION_PAGE = 0
private const val LOCAL_EFFECTS_PAGE = 1

internal fun shouldPauseConnectionDiscovery(settledPage: Int, targetPage: Int): Boolean =
    settledPage == LOCAL_EFFECTS_PAGE || targetPage == LOCAL_EFFECTS_PAGE

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
        // Release the selected 1920px source and rendered previews after returning to connection.
        // The adjacent page is composed on demand during the gesture, so no transition is lost.
        beyondViewportPageCount = 0,
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
            LOCAL_EFFECTS_PAGE -> LocalPhotoEffectsPage(
                viewModel = transferViewModel,
                onNavigateUp = returnToConnectionPage,
            )
        }
    }
}
