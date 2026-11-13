package com.ztransfer.presets

import android.content.Context
import android.net.Uri
import com.ztransfer.lut.LutPreferences

internal enum class PresetFolderOwner { MONITOR_LUT, PHOTO_LUT, PICTURE_CONTROL, PHOTO_NP3 }

/** Transfer grant ownership to every remaining user before the old owner releases it. */
internal fun retainSharedPresetFolderGrant(context: Context, releasing: PresetFolderOwner, uri: Uri): Boolean {
    var shared = false
    for (owner in PresetFolderOwner.entries) {
        if (owner == releasing) continue
        if (owner == PresetFolderOwner.PHOTO_NP3) {
            if (com.ztransfer.filter.PhotoNp3Store(context).folders.retainSharedGrant(uri)) shared = true
        } else if (owner == PresetFolderOwner.PICTURE_CONTROL) {
            if (PictureControlFolderPreferences(context).retainSharedGrant(uri)) shared = true
        } else {
            val name = if (owner == PresetFolderOwner.MONITOR_LUT) "monitor_lut" else "photo_lut"
            val preferences = LutPreferences(context.getSharedPreferences(name, Context.MODE_PRIVATE))
            if (preferences.folder == uri) {
                preferences.markFolderGrantOwned()
                shared = true
            }
        }
    }
    return shared
}
