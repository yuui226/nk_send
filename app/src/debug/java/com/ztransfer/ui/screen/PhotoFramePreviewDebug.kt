package com.ztransfer.ui.screen

import android.content.Context
import android.util.Log

/** Debug 保留系统日志，界面不暴露临时诊断入口。 */
internal fun recordPhotoFramePreviewFailure(_context: Context, error: Throwable) {
    Log.e("PhotoFramePreview", "Unable to render frame preview", error)
}
