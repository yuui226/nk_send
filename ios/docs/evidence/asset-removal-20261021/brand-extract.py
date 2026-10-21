import hashlib
import json
from pathlib import Path

root = Path('/Users/orys/code/nk_send')
directory = Path(__file__).parent
source = root / 'ios/ZTransfer/Domain/PhotoEffects.swift'
raw = source.read_bytes()
text = raw.decode()
declarations = [
    'enum PhotoFramePreset:',
    'enum PhotoFrameBrandStyle:',
    'func normalizePhotoFrameWidthPercent(',
    'func normalizePhotoFrameBackdropPercent(',
    'private extension Int {',
    'struct PhotoFrameMetadataSettings:',
    'extension PhotoFrameMetadataSettings {',
]

def extract_declaration(prefix):
    starts = [index for index in range(len(text))
              if (index == 0 or text[index - 1] == '\n') and text.startswith(prefix, index)]
    assert len(starts) == 1, (prefix, starts)
    start = starts[0]
    brace = text.index('{', start)
    depth = 0
    state = 'code'
    escaped = False
    index = brace
    while index < len(text):
        character = text[index]
        following = text[index:index+2]
        if state == 'string':
            if escaped:
                escaped = False
            elif character == '\\':
                escaped = True
            elif character == '"':
                state = 'code'
        elif state == 'line_comment':
            if character == '\n':
                state = 'code'
        elif state == 'block_comment':
            if following == '*/':
                state = 'code'
                index += 1
        elif following == '//':
            state = 'line_comment'
            index += 1
        elif following == '/*':
            state = 'block_comment'
            index += 1
        elif character == '"':
            state = 'string'
        elif character == '{':
            depth += 1
        elif character == '}':
            depth -= 1
            if depth == 0:
                end = index + 1
                return text[start:end], {
                    'declaration': prefix,
                    'startLine': text.count('\n', 0, start) + 1,
                    'endLine': text.count('\n', 0, end) + 1,
                    'sha256': hashlib.sha256(text[start:end].encode()).hexdigest(),
                }
        index += 1
    raise AssertionError('Unterminated declaration: ' + prefix)

parts, entries = [], []
for declaration in declarations:
    part, entry = extract_declaration(declaration)
    parts.append(part)
    entries.append(entry)
generated = 'import Foundation\n\n' + '\n\n'.join(parts) + '\n'
output = directory / 'ProductionBrandMetadata.swift'
output.write_text(generated)
evidence = {
    'source': str(source),
    'sourceSha256': hashlib.sha256(raw).hexdigest(),
    'generatedFile': str(output),
    'generatedSha256': hashlib.sha256(generated.encode()).hexdigest(),
    'extraction': 'Complete unmodified declaration blocks copied from current production source; only Foundation import and separators added.',
    'declarations': entries,
    'scope': ['ordinary brand visibility cycle', 'legacy metadata JSON decode and encode', 'legacy brandStyle construction and assignment'],
    'notCovered': ['PhotoEffectsStore persistence', 'Android preference parsing', 'complete effect recipe decoding', 'preview cache', 'renderer', 'iOS UI', 'UIKit build'],
}
(directory / 'evidence.json').write_text(json.dumps(evidence, indent=2, ensure_ascii=False) + '\n')
print(json.dumps({'sourceSha256': evidence['sourceSha256'], 'declarations': len(entries)}, ensure_ascii=False))
