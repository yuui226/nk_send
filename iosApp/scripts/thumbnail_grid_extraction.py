"""Mechanical extraction of the COMPLETE original thumbnail grid, not a parallel layout.

Only image I/O, Android exported-file index, localized text and lifecycle collection are slots.
Every other byte, including gestures, lazy keys, animation numbers and effect keys, is compared.
"""
import re
import textwrap
from transfer_card_extraction import replace_once

HEADER = '''@file:OptIn(kotlin.experimental.ExperimentalObjCRefinement::class)

package com.ztransfer.ui.screen

import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.*
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.*
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.*
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.*
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.*
import com.ztransfer.protocol.CameraFileInfo
import com.ztransfer.ui.theme.*
import com.ztransfer.viewmodel.ActiveTransferProgress
import com.ztransfer.viewmodel.TransferStatus
import com.ztransfer.viewmodel.TransferTask
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

'''


def section(source, start, end):
    a = source.index(start)
    return source[a:source.index(end, a)]


def extract_thumbnail_grid(source):
    source = source.replace('\r\n', '\n')
    android = source
    pieces = []

    def move(start, end, transform=lambda s: s):
        nonlocal android
        body = section(source, start, end)
        android = replace_once(android, body, '')
        pieces.append(transform(body))

    public = lambda s: s.replace('internal ', '')
    move('data class FileGroup(', '/** 已由自动传输入口', public)
    key = next(x for x in source.splitlines(True) if x.startswith('internal fun burstCollectionGridKey'))
    android = replace_once(android, key, '')
    pieces.append(public(key) + '\n')
    move('/** 一段真实连拍。', 'internal fun exportedHandlesForUntransferredFilter(', public)
    move('internal fun buildThumbnailGridItems(', '@OptIn(ExperimentalFoundationApi::class)\n@Composable\nprivate fun ThumbnailGrid(', public)
    move('/** 缩略图只借用材质色相', '/** RSSI 的周期更新', public)
    move('/** 已完成任务与目录扫描结果', '/** Android resource adapter; all USB geometry', public)
    move('/**\n * 连拍标志：叠帧图标', '/** “未传”标志：', public)
    for name in ('BurstBadgeColor', 'ProtectBadgeColor'):
        line = next(x for x in source.splitlines(True) if x.startswith('internal val ' + name + ' ='))
        android = replace_once(android, line, '')
        pieces.append(public(line) + '\n')
    # One definition per value. Android's coordinator still uses the camera-removal reflow duration.
    for name in ('THUMBNAIL_THEME_BORDER_WIDTH', 'TYPE_BADGE_COLORED_EXTS', 'CollapsingGroup',
                 'BURST_REFLOW_DURATION_MS', 'BURST_MEMBER_ENTER_DURATION_MS', 'BURST_MEMBER_EXIT_DURATION_MS',
                 'CAMERA_REMOVAL_REFLOW_DURATION_MS', 'CAMERA_REMOVAL_ENTER_DURATION_MS', 'CAMERA_REMOVAL_EXIT_DURATION_MS'):
        line = next(x for x in source.splitlines(True) if re.match(r'private (?:val|const val|data class) '+name+r'\b', x))
        android = replace_once(android, line, '')
        if name == 'CAMERA_REMOVAL_REFLOW_DURATION_MS':
            line = replace_once(line, 'private const val ', 'const val ')
        pieces.append(line + '\n')

    group = section(source, '@Composable\nprivate fun GroupHeader(', 'internal fun buildThumbnailGridItems(')
    shared_group = replace_once(group, '    group: FileGroup,', '    group: FileGroup,\n    text: ThumbnailGridText,')
    shared_group = replace_once(shared_group, '''if (group.date == UNKNOWN_DATE_KEY) stringResource(R.string.unknown_date)
                       else formatDateHeader(group.date)''', 'text.date(group.date)')
    shared_group = replace_once(shared_group, 'stringResource(if (collapsed) R.string.cd_expand else R.string.cd_collapse)', 'text.expand(collapsed)')
    shared_group = replace_once(shared_group, 'stringResource(R.string.cd_transfer_group)', 'text.transferGroup()')
    android = replace_once(android, group, '')
    pieces.append(shared_group)

    grid = section(source, '@OptIn(ExperimentalFoundationApi::class)\n@Composable\nprivate fun ThumbnailGrid(', '@Composable\nprivate fun BurstCollectionCell(')
    remembered = section(grid, '                                val transferred = remember(', '                                ThumbnailCell(')
    shared_grid = replace_once(grid, 'private fun ThumbnailGrid(', 'fun SharedThumbnailGrid(')
    for parameter in ('existingExportIndex: ExportedOriginalIndex,', 'existingExportRevision: Long,', 'organizeTransfersByDate: Boolean,'):
        shared_grid = replace_once(shared_grid, '    '+parameter+'\n', '')
    shared_grid = replace_once(shared_grid, '    cameraViewModel: CameraViewModel,', '    thumbnails: ThumbnailGridImageSource,\n    text: ThumbnailGridText,\n    isTransferred: @Composable (CameraFileInfo) -> Boolean,')
    shared_grid = replace_once(shared_grid, '    activeProgressFlow: StateFlow<ActiveTransferProgress?>,', '    activeProgress: @Composable () -> ActiveTransferProgress?,')
    shared_grid = replace_once(shared_grid, remembered, '                                val transferred = isTransferred(file)\n')
    shared_grid = replace_once(shared_grid, '                    GroupHeader(\n', '                    GroupHeader(\n                        text = text,\n')
    shared_grid = shared_grid.replace('cameraViewModel = cameraViewModel,', 'thumbnails = thumbnails,\n                                    text = text,')
    shared_grid = replace_once(shared_grid, 'activeProgressFlow = activeProgressFlow,', 'activeProgress = activeProgress,')
    shared_grid = replace_once(shared_grid, 'LoadingMoreRow()', 'LoadingMoreRow(text)')
    signature = grid[:grid.index('    val colors = AppTheme.colors')]
    arguments = re.findall(r'^    (\w+):', signature, re.M)
    omitted = {'existingExportIndex', 'existingExportRevision', 'organizeTransfersByDate', 'cameraViewModel', 'activeProgressFlow'}
    wrapper = signature + '    SharedThumbnailGrid(\n'
    wrapper += ''.join(f'        {name} = {name},\n' for name in arguments if name not in omitted)
    wrapper += '''        thumbnails = remember(cameraViewModel) { AndroidThumbnailGridImages(cameraViewModel) },
        text = AndroidThumbnailGridText,
        activeProgress = { activeProgressFlow.collectAsStateWithLifecycle().value },
        isTransferred = { file ->
'''
    wrapper += textwrap.indent(textwrap.dedent(remembered).replace('val transferred = ', '', 1), '            ')
    wrapper += '        },\n    )\n}\n\n'
    android = replace_once(android, grid, wrapper)
    pieces.append(shared_grid)

    burst = section(source, '@Composable\nprivate fun BurstCollectionCell(', '@Composable\ninternal fun BurstStackPhoto(')
    shared_burst = replace_once(burst, '    cameraViewModel: CameraViewModel,', '    thumbnails: ThumbnailGridImageSource,\n    text: ThumbnailGridText,')
    shared_burst = replace_once(shared_burst, 'stringResource(R.string.burst_collection_a11y, files.size)', 'text.burstAccessibility(files.size)')
    shared_burst = replace_once(shared_burst, 'stringResource(R.string.cd_transfer_group)', 'text.transferGroup()')
    shared_burst = replace_once(shared_burst, '''stringResource(
                        if (expanded) R.string.cd_collapse else R.string.cd_expand
                    )''', 'text.expand(!expanded)')
    shared_burst = replace_once(shared_burst, '                    BurstStackPhoto(', '                    SharedBurstStackPhoto(')
    shared_burst = replace_once(shared_burst, 'cameraViewModel = cameraViewModel,', 'thumbnails = thumbnails,')
    shared_burst = replace_once(shared_burst, '        BurstCollectionBadge(', '        SharedBurstCollectionBadge(\n            text = text,')
    android = replace_once(android, burst, '')
    pieces.append(shared_burst)

    stack = section(source, '@Composable\ninternal fun BurstStackPhoto(', '@OptIn(ExperimentalFoundationApi::class)\n@Composable\nprivate fun ThumbnailCell(')
    stack_load = section(stack, '    var thumbnail by remember(file.handle)', '    val shape = RoundedCornerShape(10.dp)')
    shared_stack = replace_once(stack, 'internal fun BurstStackPhoto(', 'fun SharedBurstStackPhoto(')
    shared_stack = replace_once(shared_stack, '    cameraViewModel: CameraViewModel,', '    thumbnails: ThumbnailGridImageSource,')
    shared_stack = replace_once(shared_stack, stack_load, '    val thumbnail = thumbnails.stack(file, transfersBusy, loadEnabled, allowRemoteThumbnail)\n')
    wrapper = stack[:stack.index('    val colors = AppTheme.colors')] + '''    SharedBurstStackPhoto(
        file = file, thumbnails = remember(cameraViewModel) { AndroidThumbnailGridImages(cameraViewModel) },
        transfersBusy = transfersBusy, loadEnabled = loadEnabled, allowRemoteThumbnail = allowRemoteThumbnail,
        showPlaceholderIcon = showPlaceholderIcon, modifier = modifier,
    )
}

'''
    android = replace_once(android, stack, wrapper)
    pieces.append(shared_stack)

    cell = section(source, '@OptIn(ExperimentalFoundationApi::class)\n@Composable\nprivate fun ThumbnailCell(', '/** 已完成任务与目录扫描结果')
    photo_load = section(cell, '    // 已加载的缩略图按 handle 记住', '    DisposableEffect(file.handle, cellBoundsRegistry)')
    shared_cell = replace_once(cell, photo_load, '    val thumbnail = thumbnails.photo(file, transfersBusy, allowRemoteThumbnail)\n')
    shared_cell = replace_once(shared_cell, '    cameraViewModel: CameraViewModel,', '    thumbnails: ThumbnailGridImageSource,\n    text: ThumbnailGridText,')
    shared_cell = replace_once(shared_cell, '    activeProgressFlow: StateFlow<ActiveTransferProgress?>,', '    activeProgress: @Composable () -> ActiveTransferProgress?,')
    shared_cell = replace_once(shared_cell, 'stringResource(R.string.filter_protected)', 'text.protectedPhoto()')
    shared_cell = replace_once(shared_cell, 'TransferStatusIndicator(', 'SharedTransferStatusIndicator(')
    shared_cell = replace_once(shared_cell, 'activeProgressFlow = activeProgressFlow,', 'activeProgress = activeProgress,')
    android = replace_once(android, cell, '')
    pieces.append(shared_cell)

    loading = section(source, '@Composable\nprivate fun LoadingMoreRow()', 'private fun formatDateHeader(')
    android = replace_once(android, loading, '')
    pieces.append(replace_once(replace_once(loading, 'LoadingMoreRow()', 'LoadingMoreRow(text: ThumbnailGridText)'), 'stringResource(R.string.loading_more)', 'text.loading()'))

    badge = section(source, '/** 合集数量角标：', '/**\n * 缩略图右下角传输状态角标:')
    shared_badge = replace_once(badge, 'internal fun BurstCollectionBadge(', 'fun SharedBurstCollectionBadge(\n    text: ThumbnailGridText,')
    shared_badge = replace_once(shared_badge, 'stringResource(R.string.burst_collection_count, animatedCount)', 'text.burstCount(animatedCount)')
    wrapper = badge[:badge.index('    val colors = AppTheme.colors')] + '''    SharedBurstCollectionBadge(AndroidThumbnailGridText, count, modifier, iconSize)
}

'''
    android = replace_once(android, badge, wrapper)
    pieces.append(shared_badge)

    status = section(source, '/**\n * 缩略图右下角传输状态角标:', '/** 打包幕的单个')
    shared_status = replace_once(status, 'internal fun TransferStatusIndicator(', 'fun SharedTransferStatusIndicator(')
    shared_status = replace_once(shared_status, '    activeProgressFlow: StateFlow<ActiveTransferProgress?>,', '    activeProgress: @Composable () -> ActiveTransferProgress?,')
    shared_status = replace_once(shared_status, 'val liveProgress by activeProgressFlow.collectAsStateWithLifecycle()', 'val liveProgress = activeProgress()')
    wrapper = status[:status.index('    val colors = AppTheme.colors')] + '''    SharedTransferStatusIndicator(task) { activeProgressFlow.collectAsStateWithLifecycle().value }
}

'''
    android = replace_once(android, status, wrapper)
    pieces.append(shared_status)

    adapters = '''private class AndroidThumbnailGridImages(private val cameraViewModel: CameraViewModel) : ThumbnailGridImageSource {
    @Composable override fun photo(file: CameraFileInfo, transfersBusy: Boolean, allowRemoteThumbnail: Boolean): ImageBitmap? {
''' + textwrap.indent(photo_load, '    ') + '''        return thumbnail
    }
    @Composable override fun stack(file: CameraFileInfo, transfersBusy: Boolean, loadEnabled: Boolean, allowRemoteThumbnail: Boolean): ImageBitmap? {
''' + textwrap.indent(stack_load, '    ') + '''        return thumbnail
    }
}

private object AndroidThumbnailGridText : ThumbnailGridText {
    @Composable override fun date(value: String): String =
        if (value == UNKNOWN_DATE_KEY) stringResource(R.string.unknown_date) else formatDateHeader(value)
    @Composable override fun expand(collapsed: Boolean): String = stringResource(if (collapsed) R.string.cd_expand else R.string.cd_collapse)
    @Composable override fun transferGroup(): String = stringResource(R.string.cd_transfer_group)
    @Composable override fun burstAccessibility(count: Int): String = stringResource(R.string.burst_collection_a11y, count)
    @Composable override fun burstCount(count: Int): String = stringResource(R.string.burst_collection_count, count)
    @Composable override fun protectedPhoto(): String = stringResource(R.string.filter_protected)
    @Composable override fun loading(): String = stringResource(R.string.loading_more)
}

'''
    android = replace_once(android, 'private fun formatDateHeader(', adapters + 'private fun formatDateHeader(')
    shared = HEADER + ''.join(pieces)
    # Do not leak function-valued Compose slots to the Objective-C surface; Swift enters via UIKit.
    for name in ('SharedThumbnailGrid', 'SharedTransferStatusIndicator', 'SharedBurstStackPhoto', 'SharedBurstCollectionBadge'):
        shared = replace_once(shared, '@Composable\nfun '+name+'(', '@kotlin.native.HiddenFromObjC\n@Composable\nfun '+name+'(')
    return android, shared.rstrip() + '\n'
