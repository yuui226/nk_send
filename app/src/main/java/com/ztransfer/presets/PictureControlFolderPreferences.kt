package com.ztransfer.presets

import android.content.Context
import android.net.Uri

internal class PictureControlFolderPreferences(context: Context) {
    private val preferences = context.getSharedPreferences("picture_control_folder", Context.MODE_PRIVATE)
    val folder: Uri? get() = preferences.getString("folder", null)?.let(Uri::parse)
    val ownsGrant: Boolean get() = preferences.getBoolean("owns_grant", false)
    fun replace(uri: Uri, owned: Boolean) {
        preferences.edit().putString("folder", uri.toString()).putBoolean("owns_grant", owned)
            .remove("use_folder").apply()
    }
    fun retainSharedGrant(uri: Uri): Boolean = (folder == uri).also { shared ->
        if (shared) preferences.edit().putBoolean("owns_grant", true).apply()
    }
}
