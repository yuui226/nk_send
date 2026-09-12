package com.ztransfer.filter

/** 用户筛选滤镜的稳定分类；分类属于目录元数据，不参与像素渲染。 */
enum class PhotoFilterCategory(val title: String) {
    ALL("全部"), FAVORITES("收藏"), LANDSCAPE("风景"), PORTRAIT("人像"),
    MONOCHROME("黑白"), FILM("胶片"), CINEMATIC("电影感"), COLOR("色彩")
}

fun PhotoFilterPreset.category(): PhotoFilterCategory = when {
    name.contains("黑白") || name.contains("单色") || name.contains("Mono", true) -> PhotoFilterCategory.MONOCHROME
    name.contains("人像") || name.contains("Portrait", true) || name.contains("Skin", true) || name.contains("Love Glow", true) || name.contains("Warm Portrait", true) || name.contains("Soft Portrait", true) -> PhotoFilterCategory.PORTRAIT
    name.contains("风景") || name.contains("Landscape", true) || name.contains("Nature", true) || name.contains("Forest", true) || name.contains("Fern", true) || name.contains("Moss", true) || name.contains("Urban Green", true) || name.contains("Blue Hour", true) || name.contains("Sunset", true) -> PhotoFilterCategory.LANDSCAPE
    name.contains("电影") || name.contains("Cine", true) || name.contains("Cinema", true) || name.contains("Teal and Orange", true) || name.contains("Dusk", true) -> PhotoFilterCategory.CINEMATIC
    name.contains("胶片") || name.contains("Film", true) || name.contains("Vintage", true) || name.contains("Darkroom", true) -> PhotoFilterCategory.FILM
    else -> PhotoFilterCategory.COLOR
}

fun List<PhotoFilterPreset>.filterByCategory(category: PhotoFilterCategory): List<PhotoFilterPreset> =
    if (category == PhotoFilterCategory.ALL || category == PhotoFilterCategory.FAVORITES) this
    else filter { it.category() == category }

fun List<PhotoFilterPreset>.orderForCategory(
    category: PhotoFilterCategory,
    favoriteCatalogKeys: List<String>,
    catalogKeyOf: (PhotoFilterPreset) -> String,
): List<PhotoFilterPreset> {
    val candidates = if (category == PhotoFilterCategory.FAVORITES) {
        filter { catalogKeyOf(it) in favoriteCatalogKeys }
    } else filterByCategory(category)
    return com.ztransfer.effects.orderWithFavorites(candidates, favoriteCatalogKeys, catalogKeyOf)
}

