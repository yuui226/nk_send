#!/usr/bin/env python3
"""Execute Compose 1.7.6 horizon color animations; Android code is reference-only."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import runpy
import subprocess
import tempfile
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    helpers = runpy.run_path(str(Path(__file__).with_name("generate-android-material-fixtures.py")))
    artifact = helpers["artifact"]
    cache = Path.home() / ".gradle/caches/modules-2/files-2.1"
    compiler = [artifact(cache, group, name, version) for group, name, version in [
        ("org.jetbrains.kotlin", "kotlin-compiler-embeddable", "1.9.20"),
        ("org.jetbrains.kotlin", "kotlin-stdlib", "1.9.20"),
        ("org.jetbrains.kotlin", "kotlin-script-runtime", "1.9.20"),
        ("org.jetbrains.kotlin", "kotlin-reflect", "1.6.10"),
        ("org.jetbrains.kotlin", "kotlin-daemon-embeddable", "1.9.20"),
        ("org.jetbrains.intellij.deps", "trove4j", "1.0.20200330"),
        ("org.jetbrains", "annotations", "13.0"),
    ]]
    driver = r'''
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.graphics.colorspace.ColorSpaces
import androidx.compose.animation.VectorConverter
import androidx.compose.animation.core.*

fun main() {
    val pairs = listOf(0xFFFFC857L to 0xFF52F58BL, 0xFF52F58BL to 0xFFFFC857L,
        0xA6FFFFFFL to 0xFF52F58BL, 0x42FFFFFFL to 0x6152F58BL)
    val converter = Color.VectorConverter(ColorSpaces.Srgb)
    for ((start, end) in pairs) {
        val animation = TargetBasedAnimation(tween<Color>(160), converter, Color(start), Color(end))
        for (ms in listOf(0L, 8L, 16L, 32L, 50L, 80L, 120L, 159L, 160L)) {
            println("sample|${start.toString(16)}|${end.toString(16)}|0|$ms|${animation.getValueFromNanos(ms*1000000).toArgb().toUInt().toString(16)}")
        }
        val interrupted = TargetBasedAnimation(tween<Color>(160), converter,
            animation.getValueFromNanos(50000000), Color(start), animation.getVelocityVectorFromNanos(50000000))
        for (ms in listOf(0L, 8L, 16L, 32L, 80L, 159L, 160L)) {
            println("sample|${start.toString(16)}|${end.toString(16)}|50|$ms|${interrupted.getValueFromNanos(ms*1000000).toArgb().toUInt().toString(16)}")
        }
    }
}
'''
    with tempfile.TemporaryDirectory(prefix="ztransfer-compose-color-") as directory:
        temporary = Path(directory)
        jars = [compiler[1], artifact(cache, "androidx.collection", "collection-jvm", "1.4.0")]
        provenance = []
        for name in ["ui-graphics-android", "ui-util-android", "ui-unit-android", "ui-geometry-android",
                     "animation-android", "animation-core-android", "runtime-android"]:
            group = "androidx.compose.animation" if name.startswith("animation") else ("androidx.compose.runtime" if name.startswith("runtime") else "androidx.compose.ui")
            matches = list((cache / group / name / "1.7.6").glob("*/*.aar"))
            if len(matches) != 1:
                raise RuntimeError(f"Expected one cached {name}:1.7.6 AAR")
            data = matches[0].read_bytes()
            provenance.append({"artifact": name + ":1.7.6", "sha256": hashlib.sha256(data).hexdigest()})
            with zipfile.ZipFile(matches[0]) as archive:
                target = temporary / (name + ".jar")
                target.write_bytes(archive.read("classes.jar"))
                jars.append(str(target))
        source = temporary / "Reference.kt"
        source.write_text(driver)
        classes = temporary / "classes"
        subprocess.run(["java", "-cp", os.pathsep.join(compiler),
            "org.jetbrains.kotlin.cli.jvm.K2JVMCompiler", "-no-stdlib", "-no-reflect",
            "-classpath", os.pathsep.join(jars), "-jvm-target", "17", "-d", str(classes), str(source)], check=True)
        result = subprocess.run(["java", "-cp", os.pathsep.join([str(classes)] + jars), "ReferenceKt"],
            capture_output=True, text=True, check=True)
    fixture = {"source": "Compose 1.7.6 TargetBasedAnimation<Color>/Color.VectorConverter", "artifacts": provenance, "samples": []}
    for line in result.stdout.splitlines():
        fields = line.split("|")
        if fields[0] == "sample":
            fixture["samples"].append({"start": fields[1].zfill(8), "end": fields[2].zfill(8),
                "interruptedAtMs": int(fields[3]), "timeMs": int(fields[4]), "result": fields[5].zfill(8)})
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(fixture, indent=2) + "\n")


if __name__ == "__main__":
    main()
