package com.ztransfer.presets

import android.content.Context
import android.net.Uri

internal class PictureControlFolderPreferences(context: Context) {
    private val preferences = context.getSharedPreferences("picture_control_folder", Context.MODE_PRIVATE)
    val folder: Uri? get() = preferences.getString("folder", null)?.let(Uri::parse)
    val ownsGrant: Boolean get() = preferences.getBoolean("owns_grant", false)
    val useFolder: Boolean get() = preferences.getBoolean("use_folder", false) && folder != null
    fun showFolder(value: Boolean) { preferences.edit().putBoolean("use_folder", value).apply() }
    fun replace(uri: Uri, owned: Boolean) {
        preferences.edit().putString("folder", uri.toString()).putBoolean("owns_grant", owned)
            .putBoolean("use_folder", true).apply()
    }
    fun retainSharedGrant(uri: Uri): Boolean = (folder == uri).also { shared ->
        if (shared) preferences.edit().putBoolean("owns_grant", true).apply()
    }
}
