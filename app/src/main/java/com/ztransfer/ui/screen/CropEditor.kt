package com.ztransfer.ui.screen

import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.tween
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.selection.selectable
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.animation.animateColorAsState
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathFillType
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.ztransfer.R
import com.ztransfer.crop.*
import com.ztransfer.ui.theme.AppTheme

/** Transparent editing controls inside PhotoPreviewOverlay; no new page or background. */
@OptIn(ExperimentalLayoutApi::class, ExperimentalMaterial3Api::class)
@Composable
internal fun CropEditor(
    preview: CropPreview?,
    failed: Boolean,
    failure: CropPreparationException? = null,
    bottomClearance: androidx.compose.ui.unit.Dp = 80.dp,
    placement: PreviewImagePlacement? = null,
    onImageChanged: (Rect) -> Unit = {},
    onRetry: () -> Unit,
    onCancel: () -> Unit,
    onConfirm: (JpegCropSelection, CropQueueVisual) -> Boolean,
    onFeedback: () -> Unit,
) {
    val colors = AppTheme.colors
    val geometry = remember(preview) { preview?.let { CropEditorGeometry(it.source) } }
    var touching by remember { mutableStateOf(false) }
    val gridAlpha by animateFloatAsState(if (touching) .45f else 0f, tween(120), label="cropGrid")
    var confirming by remember { mutableStateOf(false) }
    BackHandler { onCancel() }
    Box(Modifier.fillMaxSize()) {
        Box(Modifier.fillMaxSize(),
            contentAlignment=Alignment.Center) {
            if (preview != null && geometry != null) {
                Canvas(Modifier.fillMaxSize().clipToBounds()
                    .onSizeChanged {
                        if (placement!=null) geometry.initialize(placement.viewport,placement.content(preview))
                        else geometry.resize(Size(it.width.toFloat(),it.height.toFloat()))
                    }
                    .pointerInput(geometry) {
                        awaitEachGesture {
                            val down=awaitFirstDown(requireUnconsumed=false)
                            var corner=geometry.cornerAt(down.position,28.dp.toPx())
                            touching=true
                            try {
                                do {
                                    val event=awaitPointerEvent()
                                    if (!event.changes.any { it.pressed }) break
                                    if(event.changes.count { it.pressed }>1) corner=null
                                    if(corner!=null) geometry.dragCorner(corner,event.calculatePan(),48.dp.toPx())
                                    else geometry.transform(event.calculateCentroid(),event.calculatePan(),event.calculateZoom())
                                    onImageChanged(geometry.image)
                                    event.changes.forEach { it.consume() }
                                } while(event.changes.any { it.pressed })
                            } finally { touching=false }
                        }
                    }) {
                    val image=geometry.image
                    if(image.width<=0) return@Canvas
                    clipRect {
                        val frame=geometry.frame
                        val shade=Path().apply { fillType=PathFillType.EvenOdd; addRect(image.intersect(Rect(Offset.Zero,size))); addRect(frame) }
                        drawPath(shade,Color.Black.copy(alpha=.58f))
                        drawRect(Color.White.copy(alpha=.85f),frame.topLeft,frame.size,style=Stroke(1.dp.toPx()))
                        if(gridAlpha > 0f) for(i in 1..2) {
                            val x=frame.left+frame.width*i/3
                            val y=frame.top+frame.height*i/3
                            drawLine(Color.White.copy(alpha=gridAlpha),Offset(x,frame.top),Offset(x,frame.bottom),.65.dp.toPx())
                            drawLine(Color.White.copy(alpha=gridAlpha),Offset(frame.left,y),Offset(frame.right,y),.65.dp.toPx())
                        }
                        val length=16.dp.toPx()
                        listOf(frame.topLeft,Offset(frame.right,frame.top),frame.bottomRight,Offset(frame.left,frame.bottom)).forEachIndexed { i,p ->
                            val dx=if(i==0||i==3) length else -length
                            val dy=if(i<2) length else -length
                            drawLine(Color.White,p,p+Offset(dx,0f),3.dp.toPx())
                            drawLine(Color.White,p,p+Offset(0f,dy),3.dp.toPx())
                        }
                    }
                }
            } else {
                Column(horizontalAlignment=Alignment.CenterHorizontally,verticalArrangement=Arrangement.spacedBy(12.dp)) {
                    if(!failed) CircularProgressIndicator(Modifier.size(24.dp),color=colors.accentBlue,strokeWidth=2.dp)
                    val message = if (!failed) R.string.crop_loading else when (failure?.reason) {
                        CropPreparationException.Reason.ORIENTATION -> R.string.crop_orientation_failed
                        CropPreparationException.Reason.PREVIEW_READ -> R.string.crop_preview_read_failed
                        CropPreparationException.Reason.CONNECTION -> R.string.camera_not_connected
                        null -> R.string.crop_unavailable
                    }
                    Text(stringResource(message),textAlign=androidx.compose.ui.text.style.TextAlign.Center,
                        style=MaterialTheme.typography.bodySmall,color=Color.White)
                    if(failed) IconButton(onClick={onFeedback();onRetry()}) {
                        Icon(Icons.Default.Refresh,stringResource(R.string.crop_retry),tint=colors.accentBlue)
                    }
                }
            }
        }
        Row(Modifier.align(Alignment.TopStart).statusBarsPadding().padding(start=12.dp,top=4.dp),
            horizontalArrangement=Arrangement.spacedBy(8.dp)) {
            CropControl(Icons.Default.Close,R.string.crop_cancel,onClick={onFeedback();onCancel()})

        }
        Column(Modifier.align(Alignment.BottomCenter).widthIn(max=480.dp).fillMaxWidth()
            .padding(start=16.dp,end=16.dp,bottom=bottomClearance),
            verticalArrangement=Arrangement.spacedBy(4.dp)) {
            val enabled = geometry != null && !confirming
            val selectRatio: (CropRatio) -> Unit = { ratio ->
                onFeedback()
                geometry?.let { it.select(ratio); onImageChanged(it.image) }
            }
            listOf(
                listOf(CropRatio.THREE_TWO, CropRatio.FOUR_THREE, CropRatio.FIVE_FOUR, CropRatio.SIXTEEN_NINE, CropRatio.TWO_ONE),
                listOf(CropRatio.TWO_THREE, CropRatio.THREE_FOUR, CropRatio.FOUR_FIVE, CropRatio.NINE_SIXTEEN, CropRatio.ONE_TWO),
            ).forEach { ratios ->
                Row(Modifier.fillMaxWidth(),horizontalArrangement=Arrangement.spacedBy(8.dp)) {
                    ratios.forEach { ratio ->
                        CropRatioOption(ratio.title,geometry?.ratio==ratio,enabled,Modifier.weight(1f)) { selectRatio(ratio) }
                    }
                }
            }
            Row(Modifier.fillMaxWidth(),verticalAlignment=Alignment.CenterVertically,
                horizontalArrangement=Arrangement.spacedBy(12.dp)) {
                Row(Modifier.weight(1f),horizontalArrangement=Arrangement.spacedBy(8.dp)) {
                    listOf(CropRatio.FREE,CropRatio.ORIGINAL,CropRatio.SQUARE).forEach { ratio ->
                        val title=when(ratio) {
                            CropRatio.FREE -> stringResource(R.string.crop_free)
                            CropRatio.ORIGINAL -> stringResource(R.string.crop_original)
                            else -> ratio.title
                        }
                        CropRatioOption(title,geometry?.ratio==ratio,enabled,Modifier.weight(1f)) { selectRatio(ratio) }
                    }
                }
            CropControl(Icons.Default.Check,R.string.crop_confirm,geometry!=null&&geometry.size.width>0&&!confirming,
                modifier=Modifier.size(52.dp),accent=true,onClick={
                    if (geometry!=null && preview!=null) {
                        onFeedback();confirming=true
                        val displayed=geometry.selection(preview.originalOrientation)
                        confirming=onConfirm(preview.canonicalSelection(displayed),CropQueueVisual(
                            preview.image,preview.rawSelection(displayed),geometry.frame,placement?.rotation ?: 0f))
                    }
                })
            }
        }
    }
}

@Composable
private fun CropRatioOption(title: String, selected: Boolean, enabled: Boolean,
    modifier: Modifier = Modifier, onClick: () -> Unit) {
    val accent = AppTheme.colors.accentBlue
    val background by animateColorAsState(if(selected) accent.copy(alpha=.32f).compositeOver(Color(0xFF20242A)) else Color(0xFF292C31).copy(alpha=.94f),
        tween(160),label="cropRatioBackground")
    val foreground by animateColorAsState(if(selected) accent else Color.White.copy(alpha=.85f),
        tween(160),label="cropRatioForeground")
    val outline by animateColorAsState(if(selected) accent.copy(alpha=.85f) else Color.White.copy(alpha=.22f),
        tween(160),label="cropRatioOutline")
    val shape = RoundedCornerShape(12.dp)
    Box(modifier.height(48.dp).padding(vertical=3.dp).clip(shape)
        .background(background,shape)
        .border(1.dp,outline.copy(alpha=if(enabled) outline.alpha else .1f),shape)
        .selectable(selected=selected,enabled=enabled,role=Role.RadioButton,onClick=onClick),
        contentAlignment=Alignment.Center) {
        Text(title,color=foreground.copy(alpha=if(enabled) foreground.alpha else .35f),
            style=MaterialTheme.typography.labelMedium,fontWeight=FontWeight.Medium,maxLines=1)
    }
}

@Composable
private fun CropControl(icon: androidx.compose.ui.graphics.vector.ImageVector, label: Int,
    enabled: Boolean=true, modifier: Modifier=Modifier.size(44.dp),accent: Boolean=false,onClick:()->Unit) {
    val colors=AppTheme.colors
    if(accent) {
        GlassButton(onClick=onClick,enabled=enabled,modifier=modifier,
            shape=CircleShape,contentPadding=PaddingValues(0.dp)) {
            Icon(icon,stringResource(label),tint=colors.accentBlue.copy(alpha=if(enabled) 1f else .35f))
        }
    } else IconButton(onClick=onClick,enabled=enabled,
        modifier=modifier.background(Color.Black.copy(alpha=.45f),CircleShape)) {
        Icon(icon,stringResource(label),tint=Color.White.copy(alpha=if(enabled) 1f else .35f))
    }
}
