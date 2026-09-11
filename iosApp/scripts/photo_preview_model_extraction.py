"""Move only original platform-neutral preview rules; preserve Android date/URI/IO behavior."""
import re
from thumbnail_grid_extraction import section
from transfer_card_extraction import replace_once


def extract_photo_preview_model(source):
    source=source.replace('\r\n','\n')
    enums=section(source,'internal enum class PreviewQueueDragDirection','internal fun localOriginalPreviewRoute(')
    intent=section(source,'internal fun <T> isLocalPreviewResolved(','/** PTP DateTime')
    paging=section(source,'/** 预览分页模型与列表展示模型同构','/**\n * 全屏预览层')
    ratio='private const val PREVIEW_QUEUE_DIRECTION_RATIO = 1.15f\n'
    android=source
    for block in (enums,intent,paging,ratio): android=replace_once(android,block,'')
    shared='''@file:OptIn(kotlin.experimental.ExperimentalObjCRefinement::class)

package com.ztransfer.ui.screen

import androidx.compose.ui.geometry.Offset
import com.ztransfer.protocol.CameraFileInfo
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

'''+ratio+'\n'+enums+intent+paging
    shared=shared.replace('internal enum class ','@kotlin.native.HiddenFromObjC\npublic enum class ')
    shared=shared.replace('internal sealed interface ','@kotlin.native.HiddenFromObjC\npublic sealed interface ')
    shared=shared.replace('internal fun ','@kotlin.native.HiddenFromObjC\npublic fun ')
    return android,shared.rstrip()+'\n'


MIGRATED_TESTS = {
    'PhotoPreviewItemsTest': ('PhotoPreviewPagingTest',[
        'expansionInsertsMembersImmediatelyAfterPersistentCollectionPage',
        'expansionIsIdempotentAndCollapseOnlyRemovesTargetMembers',
        'everyMemberInSmallAndLargeBurstsReturnsToTheSameCollectionPage',
        'localOriginalSourcesStayFrozenUntilThePreviewIsReopened']),
    'PhotoPreviewQueueGestureTest': ('PhotoPreviewQueueIntentTest',[
        'upwardIntentOnlyWinsAfterSlopAndClearDirection',
        'horizontalAndDownwardDragsStayWithExistingGestures',
        'visualDragTracksFingerThenAddsResistanceAfterTrigger']),
    'ThumbnailPreviewPriorityTest': ('PhotoPreviewLoadPriorityTest',[
        'missingLocalOriginalNeverSuppressesCurrentCameraFhd',
        'previewFallbackWaitsForCurrentFhdAndExifToFinish']),
}


def extract_preview_tests(source, name):
    source=source.replace('\r\n','\n')
    shared_name,selected=MIGRATED_TESTS[name]
    header=source[:source.index('    @Test\n')]
    methods=list(re.finditer(r'    @Test\n    fun (\w+)\(',source))
    parts=[]; android=source
    for i,match in enumerate(methods):
        if match.group(1) not in selected: continue
        end=methods[i+1].start() if i+1<len(methods) else source.rindex('\n}')
        body=source[match.start():end]
        android=replace_once(android,body,'')
        parts.append(body)
    assert len(parts)==len(selected)
    shared=header+''.join(parts).rstrip()+'\n}\n'
    shared=shared.replace('org.junit.Assert.','kotlin.test.').replace('org.junit.Test','kotlin.test.Test')
    shared=shared.replace('class '+name+' {','class '+shared_name+' {')
    return android,shared
