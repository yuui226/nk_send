#!/usr/bin/env python3
"""Convert editor icons from Compose 1.7.6 source jars to Swift paths."""
import argparse
import hashlib
import re
import struct
import zipfile
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--core', required=True)
parser.add_argument('--extended', required=True)
parser.add_argument('--output', required=True)
a = parser.parse_args()
icons = [('settings', a.core, 'filled/Settings.kt'), ('check', a.core, 'filled/Check.kt'),
         ('videocam', a.extended, 'filled/Videocam.kt'), ('visible', a.extended, 'outlined/Visibility.kt'),
         ('hidden', a.extended, 'outlined/VisibilityOff.kt'),
         ('lock', a.core, 'filled/Lock.kt'), ('lockOpen', a.extended, 'filled/LockOpen.kt'),
         ('focusArea', a.extended, 'filled/CenterFocusStrong.kt'), ('touch', a.extended, 'filled/TouchApp.kt')]
f32 = lambda x: struct.unpack('f', struct.pack('f', x))[0]
def point(p):
    return 'CGPoint(x: %.9g, y: %.9g)' % p
out = ['// Generated from AndroidX Compose Material Icons 1.7.6; Copyright 2024 AOSP.',
       '// Apache-2.0; see Resources/licenses. Regenerate with generate-android-tool-icons.py.',
       'import SwiftUI', '', 'struct RemoteEditorIcon: Shape {',
       '    enum Kind { case settings, check, videocam, visible, hidden, lock, lockOpen, focusArea, touch }',
       '    let kind: Kind', '    func path(in rect: CGRect) -> Path {',
       '        var path = Path()', '        switch kind {']
for key, jar, suffix in icons:
    with zipfile.ZipFile(jar) as z:
        name = next(n for n in z.namelist() if n.endswith('/'+suffix))
        data = z.read(name)
    body = data.decode().split('materialPath {', 1)[1].split('}', 1)[0]
    out += ['        case .'+key+':', '            // '+suffix+' SHA256 '+hashlib.sha256(data).hexdigest()]
    current = (0., 0.); origin = current; previous = None
    for command, args in re.findall(r'(\w+)\(([^)]*)\)', body):
        v = [f32(float(n.strip().removesuffix('f'))) for n in args.split(',') if n.strip()]
        relative = command.endswith('Relative')
        command = command.removesuffix('Relative')
        def xy(x, y):
            return (f32(x+current[0]), f32(y+current[1])) if relative else (x,y)
        if command == 'close':
            out += ['            path.closeSubpath()']; current = origin; previous = None; continue
        if command in ('curveTo', 'reflectiveCurveTo'):
            if command == 'curveTo':
                c1, c2, end = xy(*v[:2]), xy(*v[2:4]), xy(*v[4:])
            else:
                c1 = tuple(f32(2*x-y) for x,y in zip(current, previous)) if previous else current
                c2, end = xy(*v[:2]), xy(*v[2:])
            out += ['            path.addCurve(to: '+point(end)+', control1: '+point(c1)+', control2: '+point(c2)+')']
            current = end; previous = c2; continue
        if command in ('moveTo', 'lineTo'): end = xy(*v)
        elif command == 'horizontalLineTo': end = (f32(current[0]+v[0]) if relative else v[0], current[1])
        elif command == 'verticalLineTo': end = (current[0], f32(current[1]+v[0]) if relative else v[0])
        else: raise ValueError(command)
        if command == 'moveTo': origin = end
        out += ['            path.'+('move' if command == 'moveTo' else 'addLine')+'(to: '+point(end)+')']
        current = end; previous = None
out += ['        }', '        return path.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24))',
        '            .applying(CGAffineTransform(translationX: rect.minX, y: rect.minY))', '    }', '}']
Path(a.output).write_text('\n'.join(out)+'\n')
