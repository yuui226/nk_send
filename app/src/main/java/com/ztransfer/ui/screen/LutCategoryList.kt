package com.ztransfer.ui.screen

import android.net.Uri
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.clickable
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
import com.ztransfer.ui.theme.AppTheme

/** Caller supplies bounded height; both columns scroll independently and retain their width. */
@Composable
internal fun LutCategoryList(
    files: List<LutFile>, selected: Uri?, enabled: Boolean = true,
    modifier: Modifier = Modifier,
    content: @Composable (LutFile) -> Unit,
) {
    val categories = remember(files) { files.map { it.category }.distinct().sortedWith(
        compareBy<String?> { it != null }.thenBy(String.CASE_INSENSITIVE_ORDER) { it.orEmpty() }) }
    var category by remember { mutableStateOf(files.firstOrNull { it.uri == selected }?.category ?: categories.firstOrNull()) }
    // Background refresh must not jump away from a category the user just opened.
    LaunchedEffect(selected) {
        files.firstOrNull { it.uri == selected }?.let { category = it.category }
    }
    LaunchedEffect(categories) {
        if (category !in categories) category = categories.firstOrNull()
    }
    val colors = AppTheme.colors
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        val categoryScroll = rememberLazyListState(
            initialFirstVisibleItemIndex = categories.indexOf(category).coerceAtLeast(0))
        LazyColumn(Modifier.weight(.36f), state = categoryScroll, verticalArrangement = Arrangement.spacedBy(2.dp)) {
            items(categories.size) { index ->
                val item = categories[index]
                Surface(onClick = { category = item }, enabled = enabled,
                    shape = RoundedCornerShape(8.dp),
                    color = if (category == item) colors.accentBlue.copy(alpha = .14f) else Color.Transparent,
                    modifier = Modifier.fillMaxWidth()) {
                    Text(item ?: stringResource(R.string.lut_uncategorized),
                        style = MaterialTheme.typography.labelLarge,
                        maxLines = 2, overflow = TextOverflow.Ellipsis,
                        color = if (category == item) colors.accentBlue else colors.onSurfaceVariant,
                        modifier = Modifier.padding(horizontal = 8.dp, vertical = 10.dp))
                }
            }
        }
        val visible = remember(files, category) { files.filter { it.category == category } }
        // A new category starts at its first LUT instead of inheriting the previous list offset.
        key(category) {
            val optionScroll = rememberLazyListState(
                initialFirstVisibleItemIndex = visible.indexOfFirst { it.uri == selected }.coerceAtLeast(0))
            LazyColumn(Modifier.weight(.64f), state = optionScroll, verticalArrangement = Arrangement.spacedBy(2.dp)) {
                items(visible, key = { it.uri.toString() }) { content(it) }
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
        Box(Modifier.weight(1f).clip(RoundedCornerShape(6.dp))
            .clickable(enabled = enabled, role = Role.Button, onClick = onOff)
            .heightIn(min = 30.dp).padding(horizontal = 6.dp, vertical = 5.dp),
            contentAlignment = Alignment.CenterStart) {
            Text(offLabel ?: stringResource(R.string.lut_turn_off), maxLines = 1, overflow = TextOverflow.Ellipsis,
                style = MaterialTheme.typography.labelMedium,
                color = if (off) colors.accentBlue else colors.onSurfaceVariant)
        }
        if (folderLabel != null) Box(Modifier.weight(1f).clip(RoundedCornerShape(6.dp))
            .clickable(enabled = enabled, role = Role.Button, onClick = onFolder)
            .heightIn(min = 30.dp).padding(horizontal = 6.dp, vertical = 5.dp),
            contentAlignment = Alignment.CenterEnd) {
            Text(folderLabel, maxLines = 1, overflow = TextOverflow.Ellipsis,
                style = MaterialTheme.typography.labelMedium, color = colors.onSurfaceVariant)
        }
    }
}
