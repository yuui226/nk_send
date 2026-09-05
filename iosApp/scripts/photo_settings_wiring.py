"""Exact batch-45 interaction preference additions, preserving earlier whole-file baselines."""
SETTER = '''    internal fun setTapToPreview(enabled: Boolean) {
        if (closed) return
        val next = mutableLayout.value.copy(tapToPreview = enabled)
        if (next == mutableLayout.value) return
        mutableLayout.value = next
        persistPreferences()
    }
'''

def replace_once(value, old, new):
    assert value.count(old) == 1, old
    return value.replace(old, new, 1)

def without_photo_interaction_model(value):
    value = replace_once(value, SETTER, '')
    value = replace_once(value, 'NativeBrowseLayout(initialPreferences.columns, initialPreferences.collapseBursts, initialPreferences.tapToPreview)',
                         'NativeBrowseLayout(initialPreferences.columns, initialPreferences.collapseBursts)')
    value = replace_once(value, 'mutableLayout.value.copy(columns = com.ztransfer.viewmodel.normalizeThumbnailColumns(columns), collapseBursts = collapseBursts)',
                         'NativeBrowseLayout(com.ztransfer.viewmodel.normalizeThumbnailColumns(columns), collapseBursts)')
    return replace_once(value, 'mutablePreviewOptions.value.histogramEnabled, layout.tapToPreview)', 'mutablePreviewOptions.value.histogramEnabled)')

def without_photo_interaction_store(value):
    value = replace_once(value, '        var tapToPreview: Bool?\n', '')
    value = replace_once(value, ', tapToPreview: document.tapToPreview ?? false)', ')')
    return replace_once(value, ', tapToPreview: value.tapToPreview)', ')')
