#!/usr/bin/env python3
"""Refresh keyed Android strings consumed by AppLocalized; preserve iOS overrides."""
import json
import re
from pathlib import Path
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[2]
resources = root / 'app/src/main/res'
languages = {}
for language, folder in [('en', 'values'), ('zh', 'values-zh'), ('hant', 'values-b+zh+Hant')]:
    strings = {}
    for path in sorted((resources / folder).glob('*.xml')):
        for element in ET.parse(path).getroot().findall('string'):
            key = element.attrib['name']
            if key in strings:
                raise ValueError(f'Duplicate resource: {folder}/{key}')
            strings[key] = ''.join(element.itertext())
    languages[language] = strings
path = root / 'ios/ZTransfer/App/AndroidLocalization.swift'
text = path.read_text()
section = text.split('static let byResource:', 1)[1].split('\n    ]', 1)[0]
previous = [json.loads(match.group(1)) for match in re.finditer(r'^        ("[^"\n]+"):', section, re.M)]
all_keys = set().union(*(set(strings) for strings in languages.values()))
keys = [key for key in previous if key in all_keys] + sorted(all_keys - set(previous))
quote = lambda value: json.dumps(value, ensure_ascii=False)
old_rows = {json.loads(match.group(1)): (match.group(0), json.loads('{'+match.group(2)+'}'))
            for match in re.finditer(r'^        ("[^"\n]+"):\s*\[(.*)\],$', section, re.M)}
lines = []
for key in keys:
    entries = ', '.join(f'{quote(language)}: {quote(strings[key])}'
                        for language, strings in languages.items() if key in strings)
    values = {language: strings[key] for language, strings in languages.items() if key in strings}
    if key in old_rows and old_rows[key][1] == values:
        lines.append(old_rows[key][0])
    else:
        lines.append(f'        {quote(key)}: [{entries}],')
path = root / 'ios/ZTransfer/App/AndroidLocalization.swift'
text = path.read_text()
start = text.index('    static let byResource: [String: [String: String]] = [')
end = text.index('\n    ]', start) + len('\n    ]')
text = text[:start] + '    static let byResource: [String: [String: String]] = [\n' + '\n'.join(lines) + '\n    ]' + text[end:]
path.write_text(text)
print(f'Synced {len(keys)} keyed resources across {len(languages)} languages')
