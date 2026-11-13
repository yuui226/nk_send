package com.ztransfer.presets

import android.net.Uri
import android.provider.DocumentsContract

/**
 * Identify a source's SAF tree so an outgoing editor cannot save it into a replacement directory.
 * Legacy/provider URIs without tree identity retain the existing compatibility behaviour.
 */
internal fun presetSourceBelongsToFolder(source: Uri, folder: Uri): Boolean {
    fun treeIdentity(uri: Uri): Pair<String, String>? {
        if (uri.scheme != "content") return null
        val authority = uri.authority?.takeIf(String::isNotBlank) ?: return null
        val treeId = try {
            DocumentsContract.getTreeDocumentId(uri).takeIf(String::isNotBlank)
        } catch (_: IllegalArgumentException) {
            null
        } ?: return null
        return authority to treeId
    }
    val sourceTree = treeIdentity(source) ?: return true
    val folderTree = treeIdentity(folder) ?: return true
    return sourceTree == folderTree
}
