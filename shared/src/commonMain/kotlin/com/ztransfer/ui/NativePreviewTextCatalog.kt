package com.ztransfer.ui

import androidx.compose.runtime.Composable
import com.ztransfer.protocol.CameraFileInfo
import com.ztransfer.ui.screen.PreviewSessionText

/** Resource-only platform adapter. The supplied video formatter retains date/decimal locale IO. */
internal data class NativePreviewPageText(
    val burst: String, val protectedPhoto: String, val histogram: String, val rotation: String,
    val videoUnavailableLabel: String, val noPreviewLabel: String, val overFourGb: String,
    val expand: String, val collapse: String, val transfer: String,
    private val metadata: (CameraFileInfo, String) -> String,
) : PreviewSessionText {
    @Composable override fun burstLabel(): String = burst
    @Composable override fun protectedLabel(): String = protectedPhoto
    @Composable override fun histogramDescription(): String = histogram
    @Composable override fun rotationDescription(): String = rotation
    @Composable override fun videoUnavailable(): String = videoUnavailableLabel
    @Composable override fun noPreview(): String = noPreviewLabel
    @Composable override fun navigationDescription(expand: Boolean): String = if (expand) this.expand else collapse
    @Composable override fun transferDescription(): String = transfer
    @Composable override fun videoMetadata(file: CameraFileInfo): String = metadata(file, overFourGb)
}

/** Exact original values*. Not an independently translated second product UI. */
internal object NativePreviewTextCatalog {
    fun forLanguage(languageTag: String, videoMetadata: (CameraFileInfo, String) -> String): NativePreviewPageText {
        val parts = languageTag.lowercase().replace('_', '-').split('-')
        return when {
            parts.firstOrNull() != "zh" -> english(videoMetadata)
            "hant" in parts || ("hans" !in parts && parts.any { it in setOf("tw", "hk", "mo") }) -> traditional(videoMetadata)
            else -> simplified(videoMetadata)
        }
    }

    private fun english(metadata: (CameraFileInfo, String) -> String) = NativePreviewPageText(
        burst = "Burst", protectedPhoto = "Protected", histogram = "Photo histogram", rotation = "Rotate photo",
        videoUnavailableLabel = "Video playback isn’t supported yet", noPreviewLabel = "No preview", overFourGb = "Over 4 GB",
        expand = "Expand", collapse = "Collapse", transfer = "Transfer", metadata = metadata,
    )

    private fun simplified(metadata: (CameraFileInfo, String) -> String) = NativePreviewPageText(
        burst = "连拍", protectedPhoto = "保护", histogram = "照片直方图", rotation = "旋转照片",
        videoUnavailableLabel = "视频暂不支持播放", noPreviewLabel = "无预览", overFourGb = "超过 4 GB",
        expand = "展开", collapse = "收起", transfer = "传输", metadata = metadata,
    )

    private fun traditional(metadata: (CameraFileInfo, String) -> String) = NativePreviewPageText(
        burst = "連拍", protectedPhoto = "保護", histogram = "照片直方圖", rotation = "旋轉照片",
        videoUnavailableLabel = "影片暫不支援播放", noPreviewLabel = "無預覽", overFourGb = "超過 4 GB",
        expand = "展開", collapse = "收起", transfer = "傳輸", metadata = metadata,
    )
}
