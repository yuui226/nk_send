"""Exact batch-43 additions, peeled off before the older whole-model EXIF guard."""


def without_preview_options_model(value):
    additions = (
        '''    private val mutablePreviewOptions = MutableStateFlow(NativePreviewOptions(
        initialPreferences.previewRotationQuarterTurns, initialPreferences.previewHistogramEnabled))
    internal val previewOptions = mutablePreviewOptions.asStateFlow()
''',
    )
    for addition in additions:
        assert value.count(addition) == 1
        value = value.replace(addition, '', 1)
    start, end = value.index('    internal fun setPreviewRotationQuarterTurns('), value.index('    private fun persistPreferences(')
    value = value[:start] + value[end:]
    addition = '''            filter.dateRange?.startDayKey ?: 0, filter.dateRange?.endInclusiveDayKey ?: 0,
            mutablePreviewOptions.value.rotationQuarterTurns, mutablePreviewOptions.value.histogramEnabled)'''
    assert value.count(addition) == 1
    return value.replace(addition, '            filter.dateRange?.startDayKey ?: 0, filter.dateRange?.endInclusiveDayKey ?: 0)', 1)
