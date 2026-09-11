"""Compare resolved module snapshots without hiding non-Compose transitive changes."""
import argparse
from pathlib import Path


def modules(text):
    result = {}
    for line in text.splitlines():
        if not line.strip():
            continue
        key, version = line.strip().rsplit(":", 1)
        if key in result and result[key] != version:
            raise ValueError(f"Multiple resolved versions for {key}")
        result[key] = version
    return result


def differences(before, after):
    return [(key, before.get(key), after.get(key)) for key in sorted(before.keys() | after.keys())
            if before.get(key) != after.get(key)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("before", type=Path)
    parser.add_argument("after", type=Path)
    args = parser.parse_args()
    before = modules(args.before.read_text(encoding="utf-8"))
    after = modules(args.after.read_text(encoding="utf-8"))
    changes = differences(before, after)
    for key, old, new in changes:
        print(f"{key}: {old or '(added)'} -> {new or '(removed)'}")
    print(f"{len(changes)} module changes; {len(before)} -> {len(after)} resolved modules")


if __name__ == "__main__":
    main()
