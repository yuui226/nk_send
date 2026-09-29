package com.ztransfer.ui.screen

import android.net.Uri
import androidx.compose.foundation.layout.*
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
