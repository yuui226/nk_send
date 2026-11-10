#!/usr/bin/env python3
"""Capture an installed, audited Release in a new disposable simulator."""
import argparse
import json
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('group')
parser.add_argument('device_type')
args = parser.parse_args()
root = Path(__file__).resolve().parent
state_path = root / 'run-state.json'
state = json.loads(state_path.read_text())
work = Path(state['workdir'])
app = Path('/tmp/ztransfer-prepay-release-20261102/Build/Products/Release-iphonesimulator/ZTransfer.app')
result = root / f'{args.group}.xcresult'
if result.exists():
    raise SystemExit('Use a fresh group name; previous evidence is retained.')

def command(*values, check=True):
    return subprocess.run(values, check=check, text=True, capture_output=True)

identifier = command('xcrun', 'simctl', 'create', f'ZTransfer Release {args.group}',
                     args.device_type, state['runtime']).stdout.strip()
record = {'id': identifier, 'group': args.group, 'type': args.device_type, 'status': 'created'}
state['createdDevices'].append(record)
state_path.write_text(json.dumps(state, indent=2))
exit_code = 1
try:
    command('xcrun', 'simctl', 'boot', identifier)
    command('xcrun', 'simctl', 'bootstatus', identifier, '-b')
    command('xcrun', 'simctl', 'ui', identifier, 'appearance', 'light')
    command('xcrun', 'simctl', 'ui', identifier, 'content_size', 'large')
    command('xcrun', 'simctl', 'install', identifier, str(app))
    print(f'{args.group}: running capture on {identifier}', flush=True)
    with (root / f'{args.group}.log').open('w') as log:
        process = subprocess.run([
            'xcodebuild', 'test-without-building', '-project', str(work / 'ReleaseReferenceCapture.xcodeproj'),
            '-scheme', 'ReleaseReferenceCapture', '-configuration', 'Debug',
            '-destination', f'platform=iOS Simulator,id={identifier}',
            '-derivedDataPath', str(work / 'DerivedData'), '-parallel-testing-enabled', 'NO',
            '-resultBundlePath', str(result),
            '-only-testing:ReleaseReferenceCapture/ReleaseReferenceCapture/testCurrentReleaseHomeAndSettings',
            'CODE_SIGN_IDENTITY=-'], stdout=log, stderr=subprocess.STDOUT)
    exit_code = process.returncode
    record['testExitCode'] = exit_code
    record['attachmentExport'] = command('xcrun', 'xcresulttool', 'export', 'attachments',
        '--path', str(result), '--output-path', str(root / f'{args.group}-images'), check=False).returncode
finally:
    record['shutdownExitCode'] = command('xcrun', 'simctl', 'shutdown', identifier, check=False).returncode
    record['deleteExitCode'] = command('xcrun', 'simctl', 'delete', identifier, check=False).returncode
    record['status'] = 'removed' if record['deleteExitCode'] == 0 else 'cleanup-failed'
    state_path.write_text(json.dumps(state, indent=2))
print(f'{args.group}: capture exit {exit_code}', flush=True)
raise SystemExit(exit_code)
