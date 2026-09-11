package com.ztransfer.ui.theme

import com.ztransfer.R

/** Existing Android resource IDs stay in app; persisted enum names and display order stay shared. */
val SkinPreset.displayNameResId: Int
    get() = when (this) {
        SkinPreset.FROSTED_GLASS -> R.string.skin_frosted_glass
        SkinPreset.TITANIUM -> R.string.skin_titanium
        SkinPreset.WOOD -> R.string.skin_wood
        SkinPreset.CAMERA_CONTROLS -> R.string.skin_camera_controls
    }
