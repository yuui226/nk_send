package com.ztransfer.frame

import android.content.ContentResolver
import android.content.Context
import android.graphics.BitmapFactory
import android.net.Uri
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.File
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.FileAlreadyExistsException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.Locale

private const val MAX_WATERMARK_IMAGE_BYTES = 20L * 1024L * 1024L
private const val WATERMARK_COPY_BUFFER_BYTES = 128 * 1024

/**
 * 把用户选中的 Logo 复制进 App 私有目录，并用内容摘要命名。渲染从此不再依赖相册 URI；
 * 内容寻址也确保用户换图时，已经排队的旧任务仍能拿到当时那一份图片。
 */
internal fun importPhotoFrameWatermarkImage(
    context: Context,
    resolver: ContentResolver,
    sourceUri: Uri,
): Result<String> = runCatching {
    val directory = File(context.filesDir, PHOTO_FRAME_WATERMARK_IMAGE_DIRECTORY)
    check(directory.isDirectory || directory.mkdirs()) { "Cannot create watermark directory" }
    val temporary = File.createTempFile("watermark-import-", ".part", directory)
    try {
        val digest = MessageDigest.getInstance("SHA-256")
        var copied = 0L
        resolver.openInputStream(sourceUri)?.let(::BufferedInputStream)?.use { input ->
            BufferedOutputStream(temporary.outputStream(), WATERMARK_COPY_BUFFER_BYTES).use { output ->
                val buffer = ByteArray(WATERMARK_COPY_BUFFER_BYTES)
                while (true) {
                    val read = input.read(buffer)
                    if (read < 0) break
                    copied += read
                    require(copied <= MAX_WATERMARK_IMAGE_BYTES) {
                        "Watermark image exceeds 20 MB"
                    }
                    digest.update(buffer, 0, read)
                    output.write(buffer, 0, read)
                }
            }
        } ?: error("Cannot open selected watermark image")
        require(copied > 0L) { "Selected watermark image is empty" }

        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(temporary.absolutePath, bounds)
        require(bounds.outWidth > 0 && bounds.outHeight > 0) {
            "Selected file is not a supported bitmap image"
        }

        val imageHash = digest.digest().joinToString("") { byte ->
            "%02x".format(Locale.ROOT, byte.toInt() and 0xff)
        }
        val destination = photoFrameWatermarkImageFile(context, imageHash)
        if (!destination.isFile) {
            try {
                try {
                    Files.move(
                        temporary.toPath(),
                        destination.toPath(),
                        StandardCopyOption.ATOMIC_MOVE,
                    )
                } catch (_: AtomicMoveNotSupportedException) {
                    Files.move(temporary.toPath(), destination.toPath())
                }
            } catch (_: FileAlreadyExistsException) {
                // 两次并发选择同一内容时，另一份相同摘要的文件已经完整落盘即可复用。
                check(destination.isFile) { "Watermark image import raced without a destination" }
            }
        }
        imageHash
    } finally {
        if (temporary.exists()) temporary.delete()
    }
}
