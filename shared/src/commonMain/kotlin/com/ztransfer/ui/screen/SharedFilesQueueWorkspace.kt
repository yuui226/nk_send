@file:OptIn(kotlin.experimental.ExperimentalObjCRefinement::class)

package com.ztransfer.ui.screen

import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import com.ztransfer.ui.theme.Motion
import kotlinx.coroutines.flow.distinctUntilChanged

@Composable
@kotlin.native.HiddenFromObjC
fun SharedFilesQueueWorkspace(
    queueVisible: Boolean,
    onFilesSettledChanged: (Boolean) -> Unit,
    filesContent: @Composable () -> Unit,
    queueContent: @Composable () -> Unit,
    queueTopContent: @Composable () -> Unit,
) {
    val stateHolder = rememberSaveableStateHolder()
    val transition = updateTransition(
        targetState = queueVisible,
        label = "filesQueueTransition",
    )
    val currentOnFilesSettledChanged by rememberUpdatedState(onFilesSettledChanged)
    LaunchedEffect(transition) {
        snapshotFlow {
            !transition.isRunning &&
                !transition.currentState &&
                !transition.targetState
        }
            .distinctUntilChanged()
            .collect { settled -> currentOnFilesSettledChanged(settled) }
    }
    val topControlsProgress = transition.animateFloat(
        transitionSpec = {
            if (targetState) {
                tween(
                    durationMillis = 140,
                    delayMillis = Motion.QUEUE_PAGE_SLIDE_MS,
                    easing = FastOutSlowInEasing,
                )
            } else {
                tween(durationMillis = 80, easing = FastOutSlowInEasing)
            }
        },
        label = "queueTopControls",
    ) { showingQueue ->
        if (showingQueue) 1f else 0f
    }

    Box(Modifier.fillMaxSize()) {
        transition.AnimatedContent(
            modifier = Modifier.fillMaxSize(),
            transitionSpec = {
                if (targetState) {
                    val enterQueue = slideInHorizontally(Motion.queuePageSlide) { it } +
                        fadeIn(
                            tween(220, easing = FastOutSlowInEasing),
                            initialAlpha = 0.72f,
                        )
                    val exitFiles = slideOutHorizontally(Motion.queuePageSlide) { -it / 3 } +
                        fadeOut(
                            tween(Motion.PAGE_FADE_MS),
                            targetAlpha = 0.5f,
                        )
                    (enterQueue togetherWith exitFiles).apply { targetContentZIndex = 1f }
                } else {
                    val enterFiles = slideInHorizontally(Motion.queuePageSlide) { -it / 3 } +
                        fadeIn(
                            tween(Motion.PAGE_FADE_MS),
                            initialAlpha = 0.5f,
                        )
                    val exitQueue = slideOutHorizontally(Motion.queuePageSlide) { it } +
                        fadeOut(
                            tween(140, easing = FastOutSlowInEasing),
                            targetAlpha = 0.72f,
                        )
                    (enterFiles togetherWith exitQueue).apply { targetContentZIndex = 0f }
                }
            },
            contentKey = { it },
        ) { showingQueue ->
            val stateKey = if (showingQueue) "transferQueue" else "cameraFiles"
            stateHolder.SaveableStateProvider(stateKey) {
                if (showingQueue) queueContent() else filesContent()
            }
        }

        // 顶栏不参与横向位移或缩放。等正文横向转场彻底完成后才在原位淡入，避免
        // 返回/信号按钮与仍在滑出的照片页重叠；返回时则立即淡出。
        if (transition.currentState || transition.targetState) {
            Box(
                modifier = Modifier
                    .align(Alignment.TopStart)
                    .fillMaxWidth()
                    .graphicsLayer {
                        alpha = topControlsProgress.value
                    },
            ) {
                queueTopContent()
            }
        }
    }
}
