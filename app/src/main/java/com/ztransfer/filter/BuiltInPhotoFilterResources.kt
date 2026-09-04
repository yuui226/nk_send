package com.ztransfer.filter

import androidx.annotation.StringRes
import com.ztransfer.R

private val builtInPhotoFilterNameResourceIds = listOf(
    R.string.photo_filter_builtin_forest_verdure,
    R.string.photo_filter_builtin_dusk_ember,
    R.string.photo_filter_builtin_bleached_silver,
    R.string.photo_filter_builtin_blue_hour,
    R.string.photo_filter_builtin_blue_memory,
    R.string.photo_filter_builtin_british_mono,
    R.string.photo_filter_builtin_love_glow,
    R.string.photo_filter_builtin_calm_breeze,
    R.string.photo_filter_builtin_cinema_blue,
    R.string.photo_filter_builtin_cinematic_dusk,
    R.string.photo_filter_builtin_clear_portrait,
    R.string.photo_filter_builtin_cozy_autumn,
    R.string.photo_filter_builtin_dawn_hues,
    R.string.photo_filter_builtin_darkroom_film,
    R.string.photo_filter_builtin_fern_shade,
    R.string.photo_filter_builtin_classic_film,
    R.string.photo_filter_builtin_golden_dusk,
    R.string.photo_filter_builtin_soft_harmony,
    R.string.photo_filter_builtin_urban_green,
    R.string.photo_filter_builtin_matte_blue,
    R.string.photo_filter_builtin_moss_mood,
    R.string.photo_filter_builtin_green_shadows,
    R.string.photo_filter_builtin_soft_portrait,
    R.string.photo_filter_builtin_natural_link,
    R.string.photo_filter_builtin_cyan_negative,
    R.string.photo_filter_builtin_red_cyan,
    R.string.photo_filter_builtin_teal_negative,
    R.string.photo_filter_builtin_lemon_negative,
    R.string.photo_filter_builtin_amber_negative,
    R.string.photo_filter_builtin_lime_negative,
    R.string.photo_filter_builtin_pastel_pink,
    R.string.photo_filter_builtin_rose_vintage,
    R.string.photo_filter_builtin_setouchi_blue,
    R.string.photo_filter_builtin_sky_mist,
    R.string.photo_filter_builtin_soft_film,
    R.string.photo_filter_builtin_soft_glow,
    R.string.photo_filter_builtin_cool_sun_kiss,
    R.string.photo_filter_builtin_warm_sun_kiss,
    R.string.photo_filter_builtin_sunset_film,
    R.string.photo_filter_builtin_sunset_glow,
    R.string.photo_filter_builtin_teal_and_orange,
    R.string.photo_filter_builtin_gentle_clarity,
    R.string.photo_filter_builtin_turquoise_blue,
    R.string.photo_filter_builtin_vintage_color,
    R.string.photo_filter_builtin_vintage_vibe,
    R.string.photo_filter_builtin_vital_film,
    R.string.photo_filter_builtin_warm_street,
    R.string.photo_filter_builtin_warm_lowlight,
    R.string.photo_filter_builtin_warm_portrait,
    R.string.photo_filter_builtin_honey_warm,
)

private val builtInPhotoFilterNameResourcesById: Map<String, Int> by lazy {
    check(BuiltInPhotoFilters.all.size == builtInPhotoFilterNameResourceIds.size)
    BuiltInPhotoFilters.all.zip(builtInPhotoFilterNameResourceIds).associate { (filter, nameResId) ->
        filter.id to nameResId
    }
}

@StringRes
internal fun builtInPhotoFilterNameResId(filterId: String): Int? =
    builtInPhotoFilterNameResourcesById[filterId]
