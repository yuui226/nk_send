"""Read-only generator for the exact original filter/date resource strings."""
import json
import xml.etree.ElementTree as ET
from filter_overlay_extraction import KEYS


def expected_filter_catalog(root):
    result = '''package com.ztransfer.ui

import androidx.compose.runtime.Composable
import com.ztransfer.ui.screen.FilterOverlayText
import com.ztransfer.ui.screen.FilterTextKey

/** Generated/checked against Android values*. Only the numbered slot placeholder is substituted. */
internal class NativeFilterText(private val values: List<String>) : FilterOverlayText {
    @Composable override fun label(key: FilterTextKey, slot: Int): String = value(key, slot)
    fun value(key: FilterTextKey, slot: Int = 0): String = values[key.ordinal].replace("%1\\$d", "$slot")
}

internal object NativeFilterTextCatalog {
    fun forLanguage(languageTag: String): NativeFilterText {
        val parts = languageTag.lowercase().replace('_', '-').split('-')
        return when {
            parts.firstOrNull() != "zh" -> english
            "hant" in parts || ("hans" !in parts && parts.any { it in setOf("tw", "hk", "mo") }) -> traditional
            else -> simplified
        }
    }

'''
    for language, folder in [('english', 'values'), ('simplified', 'values-zh'), ('traditional', 'values-b+zh+Hant')]:
        values = {n.attrib['name']: ''.join(n.itertext()) for n in ET.parse(root/'app/src/main/res'/folder/'strings.xml').getroot() if n.tag == 'string'}
        result += '    private val '+language+' = NativeFilterText(listOf(\n'
        result += ''.join('        '+json.dumps(values[key], ensure_ascii=False).replace('$', '\\$')+', // '+key+'\n' for key in KEYS)
        result += '    ))\n\n'
    return result.rstrip()+'\n}\n'
