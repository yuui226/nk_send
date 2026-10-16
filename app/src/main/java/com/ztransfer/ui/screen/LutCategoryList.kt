package com.ztransfer.ui.screen

import android.net.Uri
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.clickable
import androidx.compose.foundation.border
import androidx.compose.ui.Alignment
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.ztransfer.R
import com.ztransfer.lut.LutFile
import com.ztransfer.presets.PresetFile
import com.ztransfer.ui.theme.AppTheme

@Composable
internal fun LutCategoryList(
    files: List<LutFile>, selected: Uri?, enabled: Boolean = true,
    modifier: Modifier = Modifier,
    content: @Composable (LutFile) -> Unit,
) = PresetCategoryList(files, selected, enabled, modifier, content)

/** Category identity is independent of its localized display name. */
internal data class PresetCategory<T>(val key: String, val label: String, val options: List<T>)

internal fun presetFileCategories(files: List<PresetFile>, uncategorized: String): List<PresetCategory<PresetFile>> =
    files.groupBy { it.category }.entries.sortedWith(
        compareBy<Map.Entry<String?, List<PresetFile>>> { it.key != null }
            .thenBy(String.CASE_INSENSITIVE_ORDER) { it.key.orEmpty() }
            .thenBy { it.key.orEmpty() }
    ).map { (name, options) ->
        PresetCategory(if (name == null) "root" else "folder:$name", name ?: uncategorized, options)
    }

@Composable
internal fun PresetCategoryList(
    files: List<PresetFile>, selected: Uri?, enabled: Boolean = true,
    modifier: Modifier = Modifier,
    content: @Composable (PresetFile) -> Unit,
) {
    val uncategorized = stringResource(R.string.lut_uncategorized)
    val categories = remember(files, uncategorized) { presetFileCategories(files, uncategorized) }
    PresetCategoryBrowser(categories, selected?.toString(), { it.uri.toString() }, enabled, modifier, content)
}

/** Caller supplies bounded height; both columns scroll independently and retain their width. */
@Composable
internal fun <T> PresetCategoryBrowser(
    categories: List<PresetCategory<T>>, selected: String?, optionKey: (T) -> String,
    enabled: Boolean = true, modifier: Modifier = Modifier,
    content: @Composable (T) -> Unit,
) {
    fun selectedCategory() = categories.firstOrNull { group -> group.options.any { optionKey(it) == selected } }?.key
    var category by remember { mutableStateOf(selectedCategory() ?: categories.firstOrNull()?.key) }
    // Background refresh must not jump away from a category the user just opened.
    LaunchedEffect(selected) { selectedCategory()?.let { category = it } }
    LaunchedEffect(categories) {
        if (categories.none { it.key == category }) category = categories.firstOrNull()?.key
    }
    val colors = AppTheme.colors
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        val categoryScroll = rememberLazyListState(
            initialFirstVisibleItemIndex = categories.indexOfFirst { it.key == category }.coerceAtLeast(0))
        LazyColumn(Modifier.weight(.36f), state = categoryScroll, verticalArrangement = Arrangement.spacedBy(2.dp)) {
            items(categories, key = { it.key }) { item ->
                Surface(onClick = { category = item.key }, enabled = enabled,
                    shape = RoundedCornerShape(8.dp),
                    color = if (category == item.key) colors.accentBlue.copy(alpha = .14f) else Color.Transparent,
                    modifier = Modifier.fillMaxWidth()) {
                    Text(item.label, style = MaterialTheme.typography.labelLarge,
                        maxLines = 2, overflow = TextOverflow.Ellipsis,
                        color = if (category == item.key) colors.accentBlue else colors.onSurfaceVariant,
                        modifier = Modifier.padding(horizontal = 8.dp, vertical = 10.dp))
                }
            }
        }
        val visible = categories.firstOrNull { it.key == category }?.options.orEmpty()
        // A new category starts at its first preset instead of inheriting the previous list offset.
        key(category) {
            val optionScroll = rememberLazyListState(
                initialFirstVisibleItemIndex = visible.indexOfFirst { optionKey(it) == selected }.coerceAtLeast(0))
            LazyColumn(Modifier.weight(.64f), state = optionScroll, verticalArrangement = Arrangement.spacedBy(2.dp)) {
                items(visible, key = optionKey) { content(it) }
            }
        }
    }
}

/** Shared compact header; global actions never scroll with either list. */
@Composable
internal fun LutChooserHeader(off: Boolean, folderLabel: String? = null, enabled: Boolean = true,
    onOff: () -> Unit, onFolder: () -> Unit = {}, offLabel: String? = null) {
    val colors = AppTheme.colors
    Row(Modifier.fillMaxWidth().padding(bottom = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.weight(1f).presetActionOutline(enabled)
            .clickable(enabled = enabled, role = Role.Button, onClick = onOff)
            .heightIn(min = 32.dp).padding(horizontal = 8.dp, vertical = 5.dp),
            contentAlignment = Alignment.Center) {
            Text(offLabel ?: stringResource(R.string.lut_turn_off), maxLines = 1, overflow = TextOverflow.Ellipsis,
                style = MaterialTheme.typography.labelMedium,
                color = if (off) colors.accentBlue else colors.onSurfaceVariant)
        }
        if (folderLabel != null) PresetFolderButton(folderLabel, enabled, Modifier.weight(1f), onFolder)
    }
}

/** Same folder action in the LUT and camera preset choosers. */
@Composable
internal fun PresetFolderButton(label: String, enabled: Boolean, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Box(modifier.presetActionOutline(enabled)
        .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
        .heightIn(min = 32.dp).padding(horizontal = 8.dp, vertical = 5.dp),
        contentAlignment = Alignment.Center) {
        Text(label, maxLines = 1, overflow = TextOverflow.Ellipsis,
            style = MaterialTheme.typography.labelMedium, color = AppTheme.colors.onSurfaceVariant)
    }
}

/** Shared lightweight outline for preset/LUT actions, without changing their hit areas. */
@Composable
internal fun Modifier.presetActionOutline(
    enabled: Boolean = true,
    color: Color = AppTheme.colors.onSurfaceVariant,
): Modifier {
    val shape = RoundedCornerShape(8.dp)
    return clip(shape).border(0.75.dp, color.copy(alpha = if (enabled) .28f else .12f), shape)
}
