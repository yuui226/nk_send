#!/usr/bin/env python3
"""Run the resolved Compose 1.7.6 animation specs to produce iOS test oracles."""
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
    artifact = runpy.run_path(str(Path(__file__).with_name("generate-android-material-fixtures.py")))["artifact"]
    cache = Path.home() / ".gradle/caches/modules-2/files-2.1"
    compiler = [artifact(cache, *coordinate) for coordinate in [
        ("org.jetbrains.kotlin", "kotlin-compiler-embeddable", "1.9.20"),
        ("org.jetbrains.kotlin", "kotlin-stdlib", "1.9.20"),
        ("org.jetbrains.kotlin", "kotlin-script-runtime", "1.9.20"),
        ("org.jetbrains.kotlin", "kotlin-reflect", "1.6.10"),
        ("org.jetbrains.kotlin", "kotlin-daemon-embeddable", "1.9.20"),
        ("org.jetbrains.intellij.deps", "trove4j", "1.0.20200330"),
        ("org.jetbrains", "annotations", "13.0"),
    ]]
    driver = r'''
import androidx.compose.animation.core.*

fun Float.bits() = toRawBits().toUInt().toString(16)
fun main() {
    val specs = linkedMapOf<String, FloatAnimationSpec>()
    for (duration in listOf(0, 80, 90, 140, 160, 180, 220)) {
        specs["tween-$duration"] = FloatTweenSpec(duration = duration)
    }
    specs["spring-400-0.5"] = FloatSpringSpec(dampingRatio = 0.5f, stiffness = 400f)
    specs["spring-360-0.58"] = FloatSpringSpec(dampingRatio = 0.58f, stiffness = 360f)
    specs["spring-1500-1"] = FloatSpringSpec(dampingRatio = 1f, stiffness = 1500f)
    val inputs = listOf(
        Triple(0f, 1f, 0f), Triple(1f, 0.965f, 0f), Triple(0.965f, 1f, 0f),
        Triple(1f, 0.970f, -0.12f), Triple(0.986f, 1f, -0.31f),
        Triple(0.982f, 1f, 0.23f), Triple(0.4f, 0f, 4f),
        Triple(1.09f, 1f, -2f), Triple(1f, 1f, 0f), Triple(0.999f, 1f, 0f)
    )
    val times = listOf(0L, 1L, 999_999L, 1_000_000L, 16_666_667L, 40_000_000L,
        79_999_999L, 80_000_000L, 90_000_000L, 140_000_000L,
        180_000_000L, 220_000_000L, 500_000_000L, 1_000_000_000L)
    for ((name, spec) in specs) for ((start, target, velocity) in inputs) {
        val duration = spec.getDurationNanos(start, target, velocity)
        println("case|$name|${start.bits()}|${target.bits()}|${velocity.bits()}|$duration")
        for (time in (times + listOf(maxOf(duration - 1L, 0L), maxOf(duration, 0L), maxOf(duration + 1L, 0L))).distinct()) {
            val value = spec.getValueFromNanos(time, start, target, velocity)
            val speed = spec.getVelocityFromNanos(time, start, target, velocity)
            println("sample|$time|${value.bits()}|${speed.bits()}")
        }
    }
    for (index in 0..1000) {
        val fraction = index / 1000f
        println("easing|${fraction.bits()}|${FastOutSlowInEasing.transform(fraction).bits()}")
    }
}
'''
    with tempfile.TemporaryDirectory(prefix="ztransfer-compose-motion-") as directory:
        temporary = Path(directory)
        jars = [compiler[1], artifact(cache, "androidx.collection", "collection-jvm", "1.4.0")]
        provenance = []
        coordinates = [("androidx.compose.animation", "animation-core-android")]
        coordinates += [("androidx.compose.ui", name) for name in
                        ["ui-graphics-android", "ui-util-android", "ui-unit-android", "ui-geometry-android"]]
        for group, name in coordinates:
            matches = list((cache / group / name / "1.7.6").glob("*/*.aar"))
            if len(matches) != 1:
                raise RuntimeError(f"Expected one cached {name}:1.7.6 AAR")
            provenance.append({"artifact": f"{group}:{name}:1.7.6",
                               "sha256": hashlib.sha256(matches[0].read_bytes()).hexdigest()})
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
    fixture = {"source": "Compose 1.7.6 FloatTweenSpec, FloatSpringSpec, FastOutSlowInEasing",
               "artifacts": provenance, "encoding": "Float32 hexadecimal bit patterns", "cases": [], "easing": []}
    for line in result.stdout.splitlines():
        fields = line.split("|")
        if fields[0] == "case":
            fixture["cases"].append(dict(spec=fields[1], start=fields[2], target=fields[3], velocity=fields[4],
                                         durationNanos=int(fields[5]), samples=[]))
        elif fields[0] == "sample":
            fixture["cases"][-1]["samples"].append(dict(nanos=int(fields[1]), value=fields[2], velocity=fields[3]))
        elif fields[0] == "easing":
            fixture["easing"].append(dict(fraction=fields[1], value=fields[2]))
        else:
            raise RuntimeError(f"Unexpected output: {line}")
    if len(fixture["cases"]) != 100 or len(fixture["easing"]) != 1001:
        raise RuntimeError("Incomplete Compose reference output")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(fixture, indent=2) + "\n")
    print(f"Generated 100 animation cases and 1001 easing samples: {args.output}")


if __name__ == "__main__":
    main()
