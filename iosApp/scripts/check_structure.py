#!/usr/bin/env python3
"""Read-only Xcode wiring check, usable on Windows. Does NOT compile or type-check Swift."""
import json
import plistlib
from pathlib import Path
import re
import xml.etree.ElementTree as ET


class OpenStepParser:
    """Parse the text plist subset used by this project, including quoted build settings."""
    token = re.compile(r'\s+|/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|[{}()=;,]|[^\s{}()=;,"]+', re.S)

    def __init__(self, text):
        self.tokens = []
        position = 0
        while position < len(text):
            match = self.token.match(text, position)
            if not match:
                raise ValueError(f"Invalid project token at {position}")
            value = match.group()
            if not (value.isspace() or value.startswith("//") or value.startswith("/*")):
                self.tokens.append(value)
            position = match.end()
        self.index = 0

    def take(self, expected=None):
        if self.index == len(self.tokens):
            raise ValueError("Unexpected end of project")
        value = self.tokens[self.index]
        self.index += 1
        if expected is not None and value != expected:
            raise ValueError(f"Expected {expected}, got {value}")
        return value

    def value(self):
        first = self.take()
        if first == "{":
            result = {}
            while self.tokens[self.index] != "}":
                key = self.value()
                self.take("=")
                if key in result:
                    raise ValueError(f"Duplicate project key {key}")
                result[key] = self.value()
                self.take(";")
            self.take("}")
            return result
        if first == "(":
            result = []
            while self.tokens[self.index] != ")":
                result.append(self.value())
                if self.tokens[self.index] != ")":
                    self.take(",")
            self.take(")")
            return result
        return json.loads(first) if first.startswith('"') else first

    def parse(self):
        result = self.value()
        if self.index != len(self.tokens):
            raise ValueError("Trailing project tokens")
        return result


def check(condition, message):
    if not condition:
        raise ValueError(message)


def main():
    root = Path(__file__).resolve().parents[1]
    project_dir = root / "ZTransfer.xcodeproj"
    project = OpenStepParser((project_dir / "project.pbxproj").read_text(encoding="utf-8")).parse()
    objects = project["objects"]

    def check_references(value):
        if isinstance(value, dict):
            for child in value.values():
                check_references(child)
        elif isinstance(value, list):
            for child in value:
                check_references(child)
        elif re.fullmatch(r"[A-F0-9]{24}", value):
            check(value in objects, f"Dangling project reference: {value}")

    check_references(project)
    main_project = objects[project["rootObject"]]
    paths = {}

    def walk(identifier, folder):
        obj = objects[identifier]
        if obj["isa"] == "PBXGroup":
            for child in obj["children"]:
                walk(child, folder / obj.get("path", ""))
        elif obj["isa"] == "PBXFileReference" and obj["sourceTree"] == "<group>":
            path = folder / obj["path"]
            check(path.is_file(), f"Source file missing: {path}")
            paths[identifier] = path.resolve()

    walk(main_project["mainGroup"], root)
    targets = {objects[identifier]["name"]: objects[identifier] for identifier in main_project["targets"]}
    for name, folder in [("ZTransfer", "ZTransfer"), ("ZTransferTests", "ZTransferTests")]:
        target = targets[name]
        sources = []
        for phase_id in target["buildPhases"]:
            phase = objects[phase_id]
            if phase["isa"] == "PBXSourcesBuildPhase":
                sources.extend(paths[objects[build_id]["fileRef"]] for build_id in phase["files"])
        check(len(sources) == len(set(sources)), f"Duplicate compiled source in {name}")
        expected = {path.resolve() for path in (root / folder).rglob("*.swift")}
        check(set(sources) == expected, f"Unwired/wrong Swift source in {name}: {set(sources) ^ expected}")
        print(f"PASS {name}: {len(sources)} Swift files wired once")

    phases = [objects[value]["isa"] for value in targets["ZTransfer"]["buildPhases"]]
    configurations = objects[targets["ZTransfer"]["buildConfigurationList"]]["buildConfigurations"]
    for identifier in configurations:
        settings = objects[identifier]["buildSettings"]
        check(settings.get("INFOPLIST_FILE") == "ZTransfer/Configuration/Info.plist", "Missing explicit Bonjour plist input")
        check(settings.get("INFOPLIST_KEY_NSLocalNetworkUsageDescription"), "Missing local network purpose")
        check(settings.get("INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription"), "Missing add-only Photos purpose")
        check(settings.get("INFOPLIST_KEY_NSBluetoothAlwaysUsageDescription"), "Missing Bluetooth purpose")
        check(settings.get("INFOPLIST_KEY_NSLocationWhenInUseUsageDescription"), "Missing foreground location purpose")
    info = plistlib.loads((root / "ZTransfer/Configuration/Info.plist").read_bytes())
    check(info.get("NSBonjourServices") == ["_ptp._tcp", "_nikon._tcp"], "Bonjour services must match browser descriptors")
    check(info.get("CADisableMinimumFrameDurationOnPhone") is True, "Missing Compose iOS frame-duration setting")
    check(phases.index("PBXShellScriptBuildPhase") < phases.index("PBXSourcesBuildPhase"), "Framework must build before Swift")
    scheme = ET.parse(project_dir / "xcshareddata/xcschemes/ZTransfer.xcscheme")
    testables = scheme.findall(".//TestAction/Testables/TestableReference")
    check(len(testables) == 1 and testables[0].get("skipped") == "NO", "Network tests are not enabled")
    for reference in scheme.findall(".//BuildableReference"):
        check(objects[reference.get("BlueprintIdentifier")]["name"] == reference.get("BlueprintName"), "Scheme target mismatch")
    check(targets["ZTransferTests"]["dependencies"], "Test target must depend on application")

    task_path = root.parent / "docs/技术调研/iOS实现任务清单.md"
    tasks = re.findall(r"^\| (IOS-[A-Z]\d+) \|", task_path.read_text(encoding="utf-8"), re.M)
    check(len(tasks) == len(set(tasks)), "Duplicate iOS task ID")
    test_source = (root / "ZTransferTests/CameraNetworkTests.swift").read_text(encoding="utf-8")
    tests = re.findall(r"func (test\w+)\(", test_source)
    print(f"PASS Xcode references, framework order and XCTest scheme; {len(tests)} test methods present (NOT RUN)")
    print(f"PASS task IDs: {len(tasks)} unique implementation/acceptance tasks")
    print("Swift compilation, Kotlin/Native export names and device behavior still require Mac verification.")


if __name__ == "__main__":
    main()
