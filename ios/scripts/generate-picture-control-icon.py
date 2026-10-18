#!/usr/bin/env python3
"""Translate the two Android Picture Control vectors; no runtime XML parsing."""
import hashlib
import re
import xml.etree.ElementTree as ET
from pathlib import Path

root = Path(__file__).resolve().parents[2]
android = '{http://schemas.android.com/apk/res/android}'
out = ['// Generated from Android ic_picture_control{,_colors}.xml by generate-picture-control-icon.py.',
       '// Preserve the 24:16 intrinsic aspect, 1249×800 viewport and scaleY=-1/translateY=740.',
       'import SwiftUI', '', 'struct RemotePictureControlGlyph: View {',
       '    @Environment(\\.remoteToolTint) private var tint',
       '    var body: some View {', '        Canvas { context, size in',
       '            let height = size.width * 16 / 24',
       '            context.translateBy(x: 0, y: (size.height - height) / 2)',
       '            context.scaleBy(x: size.width / 1249, y: height / 800)',
       '            context.translateBy(x: 0, y: 740)',
       '            context.scaleBy(x: 1, y: -1)',
       '            for (path, color) in Self.layers { context.fill(path, with: .color(color ?? tint)) }',
       '        }.frame(width: 22, height: 22)', '    }',
       '    private static let layers: [(Path, Color?)] = {', '        var layers: [(Path, Color?)] = []']
for name in ['ic_picture_control', 'ic_picture_control_colors']:
    raw = (root / 'app/src/main/res/drawable' / (name+'.xml')).read_bytes()
    out.append('        // '+name+'.xml SHA256 '+hashlib.sha256(raw).hexdigest())
    tree = ET.fromstring(raw)
    group = tree.find('group')
    assert group.attrib[android+'scaleY'] == '-1' and group.attrib[android+'translateY'] == '740'
    for element in group.findall('path'):
        tokens = re.findall('[A-Za-z]|-?(?:\d*\.)?\d+', element.attrib[android+'pathData'])
        index, current, start = 0, (0., 0.), (0., 0.)
        out += ['        do {', '            var path = Path()']
        while index < len(tokens):
            command = tokens[index]; index += 1
            assert command in 'MmLlHhVvZz', command
            if command in 'Zz':
                out.append('            path.closeSubpath()'); current = start; continue
            count = 2 if command in 'MmLl' else 1
            values = list(map(float, tokens[index:index+count])); index += count
            x,y = current
            if command in 'MmLl':
                x,y = values
                if command.islower(): x += current[0]; y += current[1]
            elif command in 'Hh': x = values[0] + (x if command.islower() else 0)
            else: y = values[0] + (y if command.islower() else 0)
            current = (x,y)
            if command in 'Mm': start = current
            out.append('            path.'+('move' if command in 'Mm' else 'addLine')+f'(to: CGPoint(x: {x:g}, y: {y:g}))')
        color = element.attrib[android+'fillColor']
        value = 'nil' if name == 'ic_picture_control' else 'Color(red: %d / 255, green: %d / 255, blue: %d / 255)' % tuple(int(color[i:i+2],16) for i in (1,3,5))
        out += ['            layers.append((path, '+value+'))', '        }']
out += ['        return layers', '    }()', '}']
(root/'ios/ZTransfer/UI/Components/RemotePictureControlGlyph.swift').write_text('\n'.join(out)+'\n')
