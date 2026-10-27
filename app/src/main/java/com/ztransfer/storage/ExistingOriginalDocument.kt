package com.ztransfer.storage

import android.content.ContentResolver
import android.net.Uri
import android.provider.DocumentsContract
import java.io.FileNotFoundException
import java.io.IOException

internal data class ExistingOriginalDocument(
    val displayName: String?,
    val size: Long?,
)

/**
 * Revalidate one cached original on an IO thread without reading its contents. A stale provider
 * row is insufficient: the document must also open for reading. Missing documents return null;
 * permission/provider failures propagate so they cannot cause a false skip or duplicate download.
 */
internal fun readExistingOriginalDocument(
    resolver: ContentResolver,
    uri: Uri,
): ExistingOriginalDocument? {
    return try {
        val cursor = resolver.query(
            uri,
            arrayOf(
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_SIZE,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
            ),
            null,
            null,
            null,
        ) ?: throw IOException("Original provider returned no cursor")
        val document = cursor.use {
            if (!it.moveToFirst()) return null
            val nameColumn = it.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            val sizeColumn = it.getColumnIndex(DocumentsContract.Document.COLUMN_SIZE)
            val mimeColumn = it.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)
            if (mimeColumn >= 0 && it.getString(mimeColumn) == DocumentsContract.Document.MIME_TYPE_DIR) {
                throw IOException("Indexed original is a directory")
            }
            ExistingOriginalDocument(
                displayName = if (nameColumn >= 0) it.getString(nameColumn) else null,
                size = if (sizeColumn >= 0 && !it.isNull(sizeColumn)) {
                    it.getLong(sizeColumn).takeIf { bytes -> bytes >= 0L }
                } else null,
            )
        }
        // Do not compare the read descriptor's length: providers may expose a redacted JPEG view.
        // The catalog size describes the saved original; opening only confirms that it still exists.
        val descriptor = resolver.openFileDescriptor(uri, "r")
            ?: throw IOException("Original provider returned no descriptor")
        descriptor.use { }
        document
    } catch (_: FileNotFoundException) {
        null
    }
}
