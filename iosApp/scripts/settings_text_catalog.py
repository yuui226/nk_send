"""Exact Android resource strings for the shared settings controls."""
import json
import re
import xml.etree.ElementTree as ET

PATH = 'shared/src/commonMain/kotlin/com/ztransfer/ui/NativeSettingsTextCatalog.kt'

def android_resource_value(value):
    # These selected values use simple Android escapes, not styled/spanned resource markup.
    # Reject an unfamiliar escape rather than silently generating different visible copy.
    escapes = {'n': '\n', 't': '\t', '\\': '\\', "'": "'", '"': '"'}
    return re.sub(r'\\(.)', lambda match: escapes[match[1]], value)

def generate(root):
    source = (root / 'shared/src/commonMain/kotlin/com/ztransfer/ui/screen/SharedSettingsControls.kt').read_text(encoding='utf-8')
    keys = re.search(r'enum class SettingsTextKey \{ ([^}]+) \}', source).group(1).split(', ')
    skins = {'FROSTED_GLASS': 'skin_frosted_glass', 'TITANIUM': 'skin_titanium', 'WOOD': 'skin_wood', 'CAMERA_CONTROLS': 'skin_camera_controls'}
    s = '''package com.ztransfer.ui

import androidx.compose.runtime.Composable
import com.ztransfer.ui.screen.SettingsControlsText
import com.ztransfer.ui.screen.SettingsTextKey
import com.ztransfer.ui.theme.SkinPreset

/** Original resource values; formatting and settings logic are not duplicated here. */
internal class NativeSettingsPageText(val title: String, val close: String,
    private val labels: Map<SettingsTextKey, String>, private val skins: Map<SkinPreset, String>,
) : SettingsControlsText {
    internal fun value(key: SettingsTextKey): String = labels.getValue(key)
    internal fun skinValue(skin: SkinPreset): String = skins.getValue(skin)
    @Composable override fun label(key: SettingsTextKey): String = value(key)
    @Composable override fun skinLabel(skin: SkinPreset): String = skinValue(skin)
}

internal object NativeSettingsTextCatalog {
    fun forLanguage(languageTag: String): NativeSettingsPageText {
        val parts = languageTag.lowercase().replace('_', '-').split('-')
        return when {
            parts.firstOrNull() != "zh" -> english
            "hant" in parts || ("hans" !in parts && parts.any { it in setOf("tw", "hk", "mo") }) -> traditional
            else -> simplified
        }
    }

'''
    def quote(value): return json.dumps(android_resource_value(value), ensure_ascii=False).replace('$', '\\$')
    for language, folder in [('english', 'values'), ('simplified', 'values-zh'), ('traditional', 'values-b+zh+Hant')]:
        resources = {n.attrib['name']: ''.join(n.itertext()) for n in ET.parse(root / 'app/src/main/res' / folder / 'strings.xml').getroot() if n.tag == 'string'}
        s += '    private val ' + language + ' = NativeSettingsPageText(\n'
        s += '        title = ' + quote(resources['settings']) + ', close = ' + quote(resources['cd_close']) + ',\n'
        s += '        labels = mapOf(\n' + ''.join('            SettingsTextKey.' + key + ' to ' + quote(resources[key]) + ',\n' for key in keys) + '        ),\n'
        s += '        skins = mapOf(\n' + ''.join('            SkinPreset.' + key + ' to ' + quote(resources[value]) + ',\n' for key, value in skins.items()) + '        ),\n    )\n\n'
    return s.rstrip() + '\n}\n'
