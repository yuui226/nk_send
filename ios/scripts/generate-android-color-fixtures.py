#!/usr/bin/env python3
"""Execute Compose 1.7.6 Color.lerp; no Android code enters the iOS product."""
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
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.graphics.colorspace.*

fun main() {
    val rgb = ColorSpaces.Srgb.adapt(Illuminant.D50) as Rgb
    val matrices = linkedMapOf("srgbToD50" to rgb.getTransform(), "d50ToSrgb" to rgb.getInverseTransform())
    val lab = ColorSpaces.Oklab
    for (name in listOf("M1", "M2", "InverseM1", "InverseM2")) {
        val field = lab.javaClass.getDeclaredField(name)
        field.isAccessible = true
        matrices[name] = field.get(null) as FloatArray
    }
    for ((name, matrix) in matrices) println("matrix|$name|" + matrix.joinToString(",") { it.toRawBits().toUInt().toString(16) })
    val pairs = listOf(
        0x00000000L to 0x4D4FC3F7L, 0x14EAF1F4L to 0x4D4FC3F7L,
        0x26FAFCFDL to 0x4D0277BDL, 0xFFD5D8DAL to 0xFF4FC3F7L,
        0xFFD5D8DAL to 0xFF0277BDL, 0xFFD5D8DAL to 0xFFFFB74DL,
        0xFFFFFFFFL to 0xFF000000L, 0xFFFF0000L to 0xFF0000FFL,
        0x013F2818L to 0xFEC89554L, 0xFFFFFFFFL to 0x00FFFFFFL,
        0xFF010203L to 0xFF030201L, 0xFFD5D8DAL to 0xFFF44336L
    )
    val fractions = listOf(-0.12f, 0f, 0.001f, 0.01f, 0.1f, 0.25f, 0.36f, 0.5f, 0.72f, 0.9f, 0.999f, 1f, 1.12f)
    for ((start, end) in pairs) for (fraction in fractions) {
        val result = lerp(Color(start), Color(end), fraction).toArgb()
        println("sample|${start.toString(16)}|${end.toString(16)}|$fraction|${result.toUInt().toString(16)}")
    }
}
'''
    with tempfile.TemporaryDirectory(prefix="ztransfer-compose-color-") as directory:
        temporary = Path(directory)
        jars = [compiler[1], artifact(cache, "androidx.collection", "collection-jvm", "1.4.0")]
        provenance = []
        for name in ["ui-graphics-android", "ui-util-android", "ui-unit-android", "ui-geometry-android"]:
            matches = list((cache / "androidx.compose.ui" / name / "1.7.6").glob("*/*.aar"))
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
    fixture = {"source": "androidx.compose.ui.graphics.lerp 1.7.6", "artifacts": provenance,
               "matrixEncoding": "Column-major Float32 bit patterns", "matrices": {}, "samples": []}
    for line in result.stdout.splitlines():
        fields = line.split("|")
        if fields[0] == "matrix": fixture["matrices"][fields[1]] = fields[2].split(",")
        elif fields[0] == "sample":
            fixture["samples"].append({"start": fields[1].zfill(8), "end": fields[2].zfill(8),
                "fraction": float(fields[3]), "result": fields[4].zfill(8)})
        else: raise RuntimeError(f"Unexpected output: {line}")
    if len(fixture["samples"]) != 156 or len(fixture["matrices"]) != 6:
        raise RuntimeError("Incomplete Compose reference output")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(fixture, indent=2) + "\n")
    print(f"Generated 156 Compose color samples: {args.output}")


if __name__ == "__main__":
    main()
