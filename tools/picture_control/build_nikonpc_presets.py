#!/usr/bin/env python3
"""Build bundled NP3 assets from the checked-in NikonPC configuration data.

Run from any directory; this is an offline asset-maintenance tool, not app code.
Keep the publisher's original 257-sample curve, without fitting a new spline.
Clarity and mid-range sharpening are zero because classic NCP has neither field.
"""

import hashlib
import json
from decimal import Decimal
from pathlib import Path
import struct

ROOT = Path(__file__).resolve().parents[2]
ASSETS = ROOT / 'app/src/main/assets/picture_controls'
SOURCE = Path(__file__).with_name('nikonpc-presets.json')
BASE_IDS = {'Standard': 0x0001, 'Neutral': 0x03C2, 'Vivid': 0x00C3}


def record(tag, data):
    return struct.pack('>II', tag, len(data)) + data


def quarter(value, minimum, maximum):
    assert minimum <= value <= maximum
    scaled = Decimal(str(value)) * 4
    assert scaled == int(scaled)
    return bytes([128 + int(scaled), 4])


def encode(preset):
    name = preset['name'].encode('ascii')
    assert 1 <= len(name) <= 19 and all(32 <= x <= 126 for x in name)
    curve = preset['curve']
    points = [(int(x), int(y)) for x, y in curve['points']]
    assert 2 <= len(points) <= 20
    assert all(0 <= x <= 255 and 0 <= y <= 255 for x, y in points)
    assert all(points[i][0] < points[i + 1][0] for i in range(len(points) - 1))
    gamma = Decimal(curve['gamma'])
    fraction = (gamma - int(gamma)) * 100
    assert fraction == int(fraction) and 0 < gamma < 10
    header = bytearray(64)
    header[:9] = bytes([0x49, 0x30, int(curve['minInput']), int(curve['maxInput']),
                       int(curve['minOutput']), int(curve['maxOutput']),
                       int(gamma), int(fraction), len(points)])
    for index, (x, y) in enumerate(points):
        header[9 + index * 2:11 + index * 2] = bytes([x, y])
    lut = preset['lut']
    assert len(lut) == 257 and all(isinstance(x, int) and 0 <= x <= 32767 for x in lut)
    tone_curve = bytes(header) + struct.pack('>257H', *lut)
    fields = {
        0x0100: b'0300', 0x0200: name.ljust(20, b'\0'),
        0x0300: struct.pack('>H', BASE_IDS[preset['base']]),
        0x0400: b'\0\0', 0x0500: b'\xff\x01',
        0x0600: quarter(preset['sharpening'], 0, 9), 0x0700: quarter(0, -5, 5),
        0x0800: b'\x01\x04', 0x0900: b'\x01\x04',  # Controlled by the custom curve.
        0x0A00: quarter(preset['saturation'], -3, 3),
        0x0B00: quarter(preset['hue'], -3, 3),
        0x0C00: b'\xff\0', 0x0D00: b'\xff\0', 0x0E00: b'\xff\x04',
        **{tag: b'\xff\x01' for tag in range(0x0F00, 0x1400, 0x100)},
        0x1400: b'\x80\x01', 0x1500: b'\xff\x0a', 0x1600: quarter(0, -5, 5),
        2: tone_curve,
    }
    return b'NCP\0' + b''.join(record(tag, data) for tag, data in fields.items()) + bytes(4)


def main():
    source = json.loads(SOURCE.read_text())
    catalog_path = ASSETS / 'catalog.json'
    catalog = json.loads(catalog_path.read_text())
    catalog['purpose'] = 'Bundled camera Picture Control presets'
    catalog['cameraValidation'] = (
        'C9 write, replace and restore confirmed by user on Z30 V1.20. '
        'NikonPC additions are conversion-tested; individual camera rendering is not yet verified.'
    )
    catalog['additionalSources'] = [{
        'id': 'nikonpc', 'publisher': 'NikonPC community', 'pageUrl': source['source'],
        'downloadedOn': source['downloadedOn'],
        'redistributionLicense': 'Not specified on the source page',
        'conversion': 'Classic NCP settings to NP3 0300; original 257-sample lutSource preserved; clarity and mid-range sharpening set to zero',
    }]
    catalog['presets'] = [entry for entry in catalog['presets'] if entry.get('sourceId') != 'nikonpc']
    for preset in source['presets']:
        data = encode(preset)
        filename = preset['name'] + '.NP3'
        (ASSETS / filename).write_bytes(data)
        catalog['presets'].append({
            'name': preset['name'], 'file': filename, 'format': 'NP3', 'formatVersion': '0300',
            'sizeBytes': len(data), 'sha256': hashlib.sha256(data).hexdigest(),
            'sourceId': 'nikonpc', 'sourcePresetPath': preset['sourcePath'],
        })
    assert len({entry['name'] for entry in catalog['presets']}) == len(catalog['presets'])
    catalog_path.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + '\n')
    print(f"Bundled {len(catalog['presets'])} presets ({sum(p['sizeBytes'] for p in catalog['presets'])} bytes)")


if __name__ == '__main__':
    main()
