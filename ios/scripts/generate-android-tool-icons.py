#!/usr/bin/env python3
"""Convert Android's resolved Material icon sources/classes to exact Swift paths."""
import argparse
import hashlib
import re
import struct
import subprocess
import zipfile
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--core', required=True)
sources = parser.add_mutually_exclusive_group(required=True)
sources.add_argument('--extended')
sources.add_argument('--extended-classes', help='Actual classes.jar when Maven publishes an empty source jar')
parser.add_argument('--version', default='1.5.4')
parser.add_argument('--output', required=True)
a = parser.parse_args()
extended = a.extended or a.extended_classes
icons = [('settings', a.core, 'filled/Settings.kt'), ('check', a.core, 'filled/Check.kt'),
         ('videocam', extended, 'filled/Videocam.kt'), ('visible', extended, 'outlined/Visibility.kt'),
         ('hidden', extended, 'outlined/VisibilityOff.kt'),
         ('lock', a.core, 'filled/Lock.kt'), ('lockOpen', extended, 'filled/LockOpen.kt'),
         ('focusArea', extended, 'filled/CenterFocusStrong.kt'), ('touch', extended, 'filled/TouchApp.kt'),
         ('volumeUp', extended, 'filled/VolumeUp.kt'), ('aspectRatio', extended, 'outlined/AspectRatio.kt'),
         ('edit', a.core, 'filled/Edit.kt'), ('arrowBack', a.core, 'filled/ArrowBack.kt')]

def read_commands(jar, suffix):
    if jar != a.extended_classes:
        with zipfile.ZipFile(jar) as z:
            name = next(n for n in z.namelist() if n.endswith('/'+suffix))
            data = z.read(name)
        body = data.decode().split('materialPath {', 1)[1].split('}', 1)[0]
        return data, re.findall(r'(\w+)\(([^)]*)\)', body)
    # The 1.5.4 extended artifact explicitly publishes fake-sources. Read its
    # public PathBuilder calls, including Float32 operands, from real bytecode.
    name = 'androidx.compose.material.icons.' + suffix[:-3].replace('/', '.') + 'Kt'
    with zipfile.ZipFile(jar) as z:
        data = z.read(name.replace('.', '/') + '.class')
    bytecode = subprocess.check_output(['javap', '-classpath', jar, '-c', name], text=True)
    commands, operands = [], []
    for line in bytecode.splitlines():
        constant = re.search(r'// float (-?[\d.Ee+]+)f', line)
        small = re.search(r'\bfconst_([012])\b', line)
        call = re.search(r'PathBuilder\.(\w+):\((F*)\)', line)
        if constant: operands.append(constant[1])
        elif small: operands.append(small[1])
        elif call:
            if call[1] == 'getNodes': break
            count = len(call[2])
            values = operands[-count:] if count else []
            assert len(values) == count, line
            commands.append((call[1], ','.join(values)))
            operands = []
    assert commands and commands[0][0] == 'moveTo', name
    return data, commands
f32 = lambda x: struct.unpack('f', struct.pack('f', x))[0]
def point(p):
    return 'CGPoint(x: %.9g, y: %.9g)' % p
out = [f'// Generated from AndroidX Compose Material Icons {a.version}; Copyright AOSP.',
       '// Apache-2.0; see Resources/licenses. Regenerate with generate-android-tool-icons.py.',
       'import SwiftUI', '', 'struct RemoteEditorIcon: Shape {',
       '    enum Kind: CaseIterable { case '+', '.join(key for key, _, _ in icons)+' }',
       '    let kind: Kind', '    func path(in rect: CGRect) -> Path {',
       '        var path = Path()', '        switch kind {']
for key, jar, suffix in icons:
    data, commands = read_commands(jar, suffix)
    origin_suffix = suffix if jar != a.extended_classes else suffix[:-3]+'Kt.class'
    out += ['        case .'+key+':', '            // '+origin_suffix+' SHA256 '+hashlib.sha256(data).hexdigest()]
    current = (0., 0.); origin = current; previous = None
    for command, args in commands:
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
