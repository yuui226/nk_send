package com.ztransfer.lut

import android.content.SharedPreferences
import android.net.Uri

/** File identity is a document URI, never its display name. Rendering state stays in memory. */
internal class LutPreferences(
    private val preferences: SharedPreferences,
    private val replaceFolderOverride: ((Uri, Boolean) -> Unit)? = null,
) {
    val folder: Uri?
        get() = preferences.getString(FOLDER, null)?.let(Uri::parse)

    val ownsFolderGrant: Boolean get() = preferences.getBoolean("remote_lut_owns_grant", false)

    fun markFolderGrantOwned() { preferences.edit().putBoolean("remote_lut_owns_grant", true).apply() }

    fun selection(movie: Boolean): Uri? =
        preferences.getString(key(movie), null)?.let(Uri::parse)

    fun select(movie: Boolean, uri: Uri?) {
        preferences.edit().putString(key(movie), uri?.toString()).apply()
    }

    /** Called only after permission and a complete enumeration of the new folder succeed. */
    fun replaceFolder(uri: Uri, ownsGrant: Boolean) {
        val replacement = replaceFolderOverride
        if (replacement != null) replacement(uri, ownsGrant)
        else writeFolderTo(preferences.edit(), uri, ownsGrant).apply()
    }

    internal fun writeFolderTo(editor: SharedPreferences.Editor, uri: Uri, ownsGrant: Boolean): SharedPreferences.Editor =
        editor.putString(FOLDER, uri.toString()).putBoolean("remote_lut_owns_grant", ownsGrant)
            .remove(key(false)).remove(key(true))

    fun clearSelections() {
        preferences.edit().remove(key(false)).remove(key(true)).apply()
    }

    private fun key(movie: Boolean) = if (movie) "remote_lut_movie" else "remote_lut_photo"
    internal companion object { const val FOLDER = "remote_lut_folder" }
}
