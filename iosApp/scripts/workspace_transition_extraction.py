"""Exact two-state workspace transition; Android navigation/queue owners remain in place."""
from pathlib import Path
import subprocess
ROOT = Path(__file__).resolve().parents[2]
BASELINE = "ad101d5"
ANDROID = "app/src/main/java/com/ztransfer/MainActivity.kt"
COMMON = "shared/src/commonMain/kotlin/com/ztransfer/ui/screen/SharedFilesQueueWorkspace.kt"
HEADER = """@file:OptIn(kotlin.experimental.ExperimentalObjCRefinement::class)

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

"""
def extract(source):
    start = source.index("@Composable\nprivate fun FilesQueueWorkspace(")
    end = source.index("/** Navigation Compose", start)
    original = source[start:end]
    common = HEADER + original.replace("private fun FilesQueueWorkspace(", "@kotlin.native.HiddenFromObjC\nfun SharedFilesQueueWorkspace(").rstrip() + "\n"
    wrapper = original[:original.index(") {") + 3] + """
    com.ztransfer.ui.screen.SharedFilesQueueWorkspace(queueVisible, onFilesSettledChanged,
        filesContent, queueContent, queueTopContent)
}

"""
    return source[:start] + wrapper + source[end:], common
def verify(root=ROOT):
    source = subprocess.check_output(["git", "show", BASELINE + ":" + ANDROID], cwd=root).decode("utf8")
    android, common = extract(source)
    assert (root / ANDROID).read_text(encoding="utf8") == android, "Android workspace transition adapter changed"
    assert (root / COMMON).read_text(encoding="utf8") == common, "Shared workspace transition changed"
def previous_workspace_transition_source(path, value):
    if path != ANDROID: return value
    source = subprocess.check_output(["git", "show", BASELINE + ":" + ANDROID], cwd=ROOT).decode("utf8")
    assert value == extract(source)[0], "Android workspace transition adapter changed"
    return source
