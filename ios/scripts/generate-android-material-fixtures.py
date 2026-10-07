#!/usr/bin/env python3
"""Run the repository's Android texture equations to produce iOS test evidence.

Kotlin is used only in a temporary directory to execute the Android reference;
it is never added to the iOS app or its build dependencies. Requires Java and
the Kotlin 1.9.20 compiler artifacts already present in the Gradle cache.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "app/src/main/java/com/ztransfer/ui/theme/SkinTexture.kt"


def artifact(cache, group, name, version):
    matches = list((cache / group / name / version).glob(f"*/{name}-{version}.jar"))
    if len(matches) != 1:
        raise RuntimeError(f"Expected one cached {group}:{name}:{version}, found {len(matches)}")
    return str(matches[0])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--gradle-cache", type=Path,
                        default=Path.home() / ".gradle/caches/modules-2/files-2.1")
    args = parser.parse_args()
    original = SOURCE.read_text()
    # Preserve all equations verbatim, excluding only Android/Compose adapters.
    equations = original[original.index("private fun packSigned("):]
    imports = "\n".join(line for line in original.splitlines()
                        if line.startswith("import kotlin.math."))
    driver = r'''
fun main() {
    val probes = intArrayOf(0, 1, -1, Int.MIN_VALUE, Int.MAX_VALUE, 17, -913, 0x5F3759DF)
    for (probe in probes) {
        println("seed|$probe|${mixSeed(probe)}|${Math.floorMod(mixSeed(probe), 12)}|${Math.floorMod(mixSeed(probe), 24)}|${Math.floorMod(mixSeed(probe), 4)}")
    }
    val indices = intArrayOf(0, 1, 127, 255, 256, 257, 4095, 8192, 16384, 32767, 32768, 49151, 65024, 65279, 65534, 65535)
    for (skin in 1..3) {
        val variants = when (skin) { 1 -> 12; 2 -> 24; else -> 4 }
        for (dark in listOf(false, true)) for (variant in 0 until variants) {
            val seed = mixSeed(0x5F3759DF xor (skin * 0x45D9F3B) xor variant)
            val pixels = when (skin) {
                1 -> titaniumTilePixels(dark, seed)
                2 -> woodTilePixels(dark, seed)
                else -> cameraControlTilePixels(dark, seed)
            }
            val bytes = java.nio.ByteBuffer.allocate(pixels.size * 4)
            for (pixel in pixels) bytes.putInt(pixel)
            val hash = java.security.MessageDigest.getInstance("SHA-256")
                .digest(bytes.array()).joinToString("") { "%02x".format(it.toInt() and 255) }
            val samples = indices.joinToString(",") { "$it:${pixels[it].toUInt().toString(16).padStart(8, '0')}" }
            println("tile|$skin|$dark|$variant|$seed|$hash|$samples")
        }
    }
}
'''
    cache = args.gradle_cache
    dependencies = [
        ("org.jetbrains.kotlin", "kotlin-compiler-embeddable", "1.9.20"),
        ("org.jetbrains.kotlin", "kotlin-stdlib", "1.9.20"),
        ("org.jetbrains.kotlin", "kotlin-script-runtime", "1.9.20"),
        ("org.jetbrains.kotlin", "kotlin-reflect", "1.6.10"),
        ("org.jetbrains.kotlin", "kotlin-daemon-embeddable", "1.9.20"),
        ("org.jetbrains.intellij.deps", "trove4j", "1.0.20200330"),
        ("org.jetbrains", "annotations", "13.0"),
    ]
    jars = [artifact(cache, *dependency) for dependency in dependencies]
    with tempfile.TemporaryDirectory(prefix="ztransfer-android-material-") as directory:
        temporary = Path(directory)
        source = temporary / "Reference.kt"
        source.write_text(imports + "\nprivate const val TILE = 256\n"
                          + "private const val TAU = (2 * PI).toFloat()\n"
                          + equations + driver)
        classes = temporary / "classes"
        subprocess.run(["java", "-cp", os.pathsep.join(jars),
                        "org.jetbrains.kotlin.cli.jvm.K2JVMCompiler",
                        "-no-stdlib", "-no-reflect", "-classpath", jars[1],
                        "-jvm-target", "17", "-d", str(classes), str(source)], check=True)
        result = subprocess.run(["java", "-cp", os.pathsep.join([str(classes), jars[1]]),
                                 "ReferenceKt"], check=True, capture_output=True, text=True)
    fixture = {
        "source": str(SOURCE.relative_to(ROOT)),
        "sourceSHA256": hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
        "compiler": "Kotlin 1.9.20, JVM target 17",
        "scope": "Unpremultiplied ARGB pixel equations; excludes Bitmap/Shader/GPU rendering",
        "tileSize": 256,
        "digestEncoding": "SHA-256 of all ARGB UInt32 pixels in row-major big-endian order",
        "seedProbes": [], "tiles": [],
    }
    for line in result.stdout.splitlines():
        fields = line.split("|")
        if fields[0] == "seed":
            fixture["seedProbes"].append(dict(zip(
                ["input", "mixed", "titaniumVariant", "woodVariant", "cameraVariant"],
                map(int, fields[1:]))))
        elif fields[0] == "tile":
            fixture["tiles"].append({
                "skinOrdinal": int(fields[1]), "dark": fields[2] == "true",
                "variant": int(fields[3]), "seed": int(fields[4]), "sha256": fields[5],
                "samples": [{"index": int(pair.split(":")[0]), "argb": pair.split(":")[1]}
                            for pair in fields[6].split(",")],
            })
        else:
            raise RuntimeError(f"Unexpected reference output: {line}")
    if len(fixture["tiles"]) != 80 or len(fixture["seedProbes"]) != 8:
        raise RuntimeError("Reference output was incomplete")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(fixture, indent=2) + "\n")
    print(f"Generated {len(fixture['tiles'])} Android reference tiles: {args.output}")


if __name__ == "__main__":
    main()
