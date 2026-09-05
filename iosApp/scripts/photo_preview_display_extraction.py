"""Exact preview presentation extraction; camera, Android clock/resources and IO stay in adapters."""
from thumbnail_grid_extraction import section
from transfer_card_extraction import replace_once
from photo_viewport_extraction import HEADER

IMPORTS = '''import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ChevronLeft
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.sp
import com.ztransfer.protocol.CameraFileInfo
import com.ztransfer.viewmodel.PhotoExif
import com.ztransfer.ui.theme.*
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive

'''

CONTRACT = '''@file:OptIn(kotlin.experimental.ExperimentalObjCRefinement::class)

package com.ztransfer.ui.screen

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.unit.Dp
import com.ztransfer.protocol.CameraFileInfo

/** These calls stay inside the original remember/effect keys, not a new image scheduler. */
@kotlin.native.HiddenFromObjC
interface PreviewPageImages {
    fun cached(handle: Int): ImageBitmap?
    suspend fun thumbnail(file: CameraFileInfo, allowRemote: Boolean): ImageBitmap?
}

/** Resolve text in the same composable positions as the original resource reads. */
@kotlin.native.HiddenFromObjC
interface PreviewPageText {
    @Composable fun videoMetadata(file: CameraFileInfo): String
    @Composable fun videoUnavailable(): String
    @Composable fun noPreview(): String
    @Composable fun navigationDescription(expand: Boolean): String
    @Composable fun transferDescription(): String
}

/** Existing grid stack/number badge adapters; the ghost always passes loadEnabled=false. */
@kotlin.native.HiddenFromObjC
interface PreviewBurstContent {
    @Composable fun accessibility(count: Int): String
    @Composable fun Photo(file: CameraFileInfo, loadEnabled: Boolean, showPlaceholderIcon: Boolean, modifier: Modifier)
    @Composable fun Badge(count: Int, iconSize: Dp, modifier: Modifier)
}
'''

ADAPTERS = '''private class AndroidPreviewPageImages(private val cameraViewModel: CameraViewModel) : PreviewPageImages {
    override fun cached(handle: Int): ImageBitmap? = cameraViewModel.cachedThumbnail(handle)
    override suspend fun thumbnail(file: CameraFileInfo, allowRemote: Boolean): ImageBitmap? =
        cameraViewModel.loadThumbnail(file = file, allowRemote = allowRemote)
}

private object AndroidPreviewPageText : PreviewPageText {
    @Composable override fun videoMetadata(file: CameraFileInfo): String = videoPreviewMetadata(
        fileSize = file.size, captureDate = file.captureDate,
        overFourGbLabel = stringResource(R.string.video_size_over_4gb),
    )
    @Composable override fun videoUnavailable(): String = stringResource(R.string.video_no_preview)
    @Composable override fun noPreview(): String = stringResource(R.string.no_preview)
    @Composable override fun navigationDescription(expand: Boolean): String =
        stringResource(if (expand) R.string.cd_expand else R.string.cd_collapse)
    @Composable override fun transferDescription(): String = stringResource(R.string.cd_transfer)
}

private class AndroidPreviewBurstContent(private val cameraViewModel: CameraViewModel) : PreviewBurstContent {
    @Composable override fun accessibility(count: Int): String = stringResource(R.string.burst_collection_a11y, count)
    @Composable override fun Photo(file: CameraFileInfo, loadEnabled: Boolean, showPlaceholderIcon: Boolean, modifier: Modifier) {
        BurstStackPhoto(file = file, cameraViewModel = cameraViewModel, transfersBusy = false,
            loadEnabled = loadEnabled, showPlaceholderIcon = showPlaceholderIcon, modifier = modifier)
    }
    @Composable override fun Badge(count: Int, iconSize: Dp, modifier: Modifier) {
        BurstCollectionBadge(count = count, iconSize = iconSize, modifier = modifier)
    }
}

'''


def public(body, old, new):
    return replace_once(body,'@Composable\nprivate fun '+old+'(', '@kotlin.native.HiddenFromObjC\n@Composable\nfun '+new+'(')


def wrapper(body, call):
    return body[:body.index(') {')+3]+'\n    '+call+'\n}\n\n'


def extract_photo_preview_display(source):
    source=source.replace('\r\n','\n')
    page=section(source,'@Composable\nprivate fun PreviewPage(', '/**\n * 照片大图共用')
    burstpage=section(source,'@Composable\nprivate fun BurstCollectionPreviewPage(', '/**\n * 合集预览与入队残影')
    stack=section(source,'@Composable\nprivate fun BurstCollectionStack(', '/** 当前合集叠片沿')
    navigation=section(source,'@Composable\nprivate fun BurstCollectionNavigationButton(', '/**\n * 底部毛玻璃参数条')
    exif=section(source,'@Composable\nprivate fun ExifMetadataBar(', '/** Preview-styled switch')
    transfer=section(source,'@Composable\nprivate fun TransferQueueButton(', '// 普通预览至少允许')
    android=source
    calls=[
        (page,'''SharedPhotoPreviewPage(file = file, images = remember(cameraViewModel) { AndroidPreviewPageImages(cameraViewModel) },
        text = AndroidPreviewPageText, uptimeMillis = { SystemClock.uptimeMillis() }, fhdBitmap = fhdBitmap,
        isLoadingFhd = isLoadingFhd, allowRemoteThumbnailFallback = allowRemoteThumbnailFallback,
        loadEnabled = loadEnabled, rotationDegrees = rotationDegrees, isCurrent = isCurrent,
        onDisplayBitmapChanged = onDisplayBitmapChanged, onZoomedChange = onZoomedChange, onTap = onTap)'''),
        (burstpage,'''SharedPreviewBurstPage(collection, remember(cameraViewModel) { AndroidPreviewBurstContent(cameraViewModel) },
        loadEnabled, isCurrent, onZoomedChange, stackMotionProgress, onTap)'''),
        (stack,'''SharedPreviewBurstStack(files, remember(cameraViewModel) { AndroidPreviewBurstContent(cameraViewModel) },
        loadEnabled, stackSize, stackMotionProgress, modifier)'''),
        (navigation,'SharedPreviewBurstNavigationButton(expand, enabled, onClick, AndroidPreviewPageText)'),
        (exif,'SharedPreviewExifMetadataBar(exif, modifier)'),
        (transfer,'SharedPreviewTransferQueueButton(onClick, AndroidPreviewPageText, modifier, buttonSize)'),
    ]
    for body,call in calls:android=replace_once(android,body,wrapper(body,call))
    for line in ['private val VIDEO_EXTENSIONS = setOf(".mov", ".mp4")\n',
                 'private const val FHD_REVEAL_DURATION_MS = 300L\n','private const val FHD_REVEAL_FRAME_MS = 16L\n']:
        android=replace_once(android,line,'')
    assert android.count('in VIDEO_EXTENSIONS') == 4
    android=android.replace('in VIDEO_EXTENSIONS','in PREVIEW_VIDEO_EXTENSIONS')
    android=replace_once(android,'/**\n * 照片大图共用',ADAPTERS+'/**\n * 照片大图共用')

    page=public(page,'PreviewPage','SharedPhotoPreviewPage')
    page=replace_once(page,'    cameraViewModel: CameraViewModel,\n',
        '    images: PreviewPageImages,\n    text: PreviewPageText,\n    uptimeMillis: () -> Long,\n')
    page=replace_once(page,'cameraViewModel.cachedThumbnail(file.handle)','images.cached(file.handle)')
    page=replace_once(page,'cameraViewModel.loadThumbnail(','images.thumbnail(')
    assert page.count('SystemClock.uptimeMillis()')==2
    page=page.replace('SystemClock.uptimeMillis()','uptimeMillis()').replace('in VIDEO_EXTENSIONS','in PREVIEW_VIDEO_EXTENSIONS')
    metadata='''                val metadata = videoPreviewMetadata(
                    fileSize = file.size,
                    captureDate = file.captureDate,
                    overFourGbLabel = stringResource(R.string.video_size_over_4gb),
                )'''
    page=replace_once(page,metadata,'                val metadata = text.videoMetadata(file)')
    for a,b in [('stringResource(R.string.video_no_preview)','text.videoUnavailable()'),
                ('stringResource(R.string.no_preview)','text.noPreview()')]:page=replace_once(page,a,b)
    constants='''@kotlin.native.HiddenFromObjC
val PREVIEW_VIDEO_EXTENSIONS = setOf(".mov", ".mp4")
private const val FHD_REVEAL_DURATION_MS = 300L
private const val FHD_REVEAL_FRAME_MS = 16L

'''

    burstpage=public(burstpage,'BurstCollectionPreviewPage','SharedPreviewBurstPage')
    burstpage=replace_once(burstpage,'    cameraViewModel: CameraViewModel,\n','    content: PreviewBurstContent,\n')
    burstpage=replace_once(burstpage,'stringResource(R.string.burst_collection_a11y, collection.files.size)','content.accessibility(collection.files.size)')
    burstpage=replace_once(burstpage,'        BurstCollectionStack(','        SharedPreviewBurstStack(')
    burstpage=replace_once(burstpage,'            cameraViewModel = cameraViewModel,','            content = content,')
    stack=public(stack,'BurstCollectionStack','SharedPreviewBurstStack')
    stack=replace_once(stack,'    cameraViewModel: CameraViewModel,\n','    content: PreviewBurstContent,\n')
    stack=replace_once(stack,'            BurstStackPhoto(','            content.Photo(')
    stack=replace_once(stack,'                cameraViewModel = cameraViewModel,\n                transfersBusy = false,\n','')
    stack=replace_once(stack,'        BurstCollectionBadge(','        content.Badge(')
    navigation=public(navigation,'BurstCollectionNavigationButton','SharedPreviewBurstNavigationButton')
    navigation=replace_once(navigation,'    onClick: () -> Unit,\n','    onClick: () -> Unit,\n    text: PreviewPageText,\n')
    navigation=replace_once(navigation,'stringResource(if (expand) R.string.cd_expand else R.string.cd_collapse)','text.navigationDescription(expand)')
    exif=public(exif,'ExifMetadataBar','SharedPreviewExifMetadataBar')
    transfer=public(transfer,'TransferQueueButton','SharedPreviewTransferQueueButton')
    transfer=replace_once(transfer,'    onClick: () -> Unit,\n','    onClick: () -> Unit,\n    text: PreviewPageText,\n')
    transfer=replace_once(transfer,'stringResource(R.string.cd_transfer)','text.transferDescription()')
    return (android,HEADER+IMPORTS+constants+page.rstrip()+'\n',
            HEADER+IMPORTS+(burstpage+stack).rstrip()+'\n',
            HEADER+IMPORTS+(navigation+exif+transfer).rstrip()+'\n',CONTRACT)
