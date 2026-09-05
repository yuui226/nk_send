#!/usr/bin/env python3
"""Offline JVM comparison using the actual cached AndroidX decoder, with only logging shimmed.

Run after :shared:testDebugUnitTest. Requires JDK 17+, Android SDK and existing Gradle caches.
Compiles test-only Java into a temporary directory; never modifies Android sources/configuration.
"""
import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--jdk', type=Path, default=os.environ.get('JAVA_HOME'))
    parser.add_argument('--android-jar', type=Path)
    parser.add_argument('--gradle-home', type=Path, default=Path(os.environ.get('GRADLE_USER_HOME', Path.home() / '.gradle')))
    args = parser.parse_args()
    if args.jdk is None:
        parser.error('Set JAVA_HOME to JDK 17+ or pass --jdk')
    sdk = os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT')
    android = args.android_jar
    if android is None and sdk:
        candidates = list((Path(sdk) / 'platforms').glob('android-*/android.jar'))
        if candidates:
            android = max(candidates, key=lambda p: int(p.parent.name.removeprefix('android-')) if p.parent.name.removeprefix('android-').isdigit() else -1)
    if android is None or not android.is_file():
        parser.error('Set ANDROID_HOME or pass --android-jar')
    cache = args.gradle_home / 'caches/modules-2/files-2.1'
    def one(pattern):
        matches = list(cache.glob(pattern))
        if len(matches) != 1:
            parser.error(f'Expected one cached artifact for {pattern}, found {len(matches)}; no download attempted')
        return matches[0]
    aar = one('androidx.exifinterface/exifinterface/1.3.7/*/exifinterface-1.3.7.aar')
    stdlib = one('org.jetbrains.kotlin/kotlin-stdlib/2.2.21/*/kotlin-stdlib-2.2.21.jar')
    shared = ROOT / 'shared/build/intermediates/runtime_library_classes_jar/debug/bundleLibRuntimeToJarDebug/classes.jar'
    if not shared.is_file():
        parser.error('Run :shared:testDebugUnitTest before this check')
    suffix = '.exe' if os.name == 'nt' else ''
    with tempfile.TemporaryDirectory(prefix='ztransfer-exif-oracle-') as directory:
        output = Path(directory)
        with zipfile.ZipFile(aar) as archive:
            archive.extract('classes.jar', output)  # Fixed member, not an untrusted archive path.
        classpath = os.pathsep.join(map(str, [output, output / 'classes.jar', shared, stdlib, android]))
        sources = [Path(__file__).parent / 'exif_oracle' / name for name in ['Log.java', 'ExifRationalOracle.java']]
        subprocess.run([str(args.jdk / 'bin' / ('javac' + suffix)), '-encoding', 'UTF-8', '-cp', classpath,
                        '-d', str(output), *map(str, sources)], check=True, timeout=60)
        print('AndroidX AAR SHA256:', hashlib.sha256(aar.read_bytes()).hexdigest(), flush=True)
        subprocess.run([str(args.jdk / 'bin' / ('java' + suffix)), '-cp', classpath, 'ExifRationalOracle'], check=True, timeout=60)


if __name__ == '__main__':
    main()
