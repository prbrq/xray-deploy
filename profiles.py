#!/usr/bin/env python3
"""Local registry of VLESS access profiles.  The file is intentionally not tracked."""

import json
import os
import re
import stat
import sys
import tempfile
import uuid
from pathlib import Path

DEFAULT_FILE = "profiles.json"
NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9 _.@-]{0,63}\Z")


def die(message: str) -> None:
    raise SystemExit(f"ERROR: {message}")


def validate_name(name: str) -> str:
    if not NAME_RE.fullmatch(name):
        die("Profile name must be 1–64 ASCII characters: letters, digits, spaces, '.', '_', '@' or '-'; it must start with a letter or digit.")
    return name


def validate_uuid(value: str) -> str:
    try:
        parsed = uuid.UUID(value)
    except ValueError:
        die("Profile UUID is invalid.")
    if str(parsed) != value.lower():
        die("Profile UUID must use the canonical hyphenated form.")
    return str(parsed)


def validate_registry(data: object) -> list[dict[str, str]]:
    if not isinstance(data, dict) or data.get("version") != 1 or not isinstance(data.get("profiles"), list):
        die("profiles registry has an unsupported format.")

    profiles = data["profiles"]
    if not profiles:
        die("profiles registry must contain at least one profile.")
    names: set[str] = set()
    uuids: set[str] = set()
    for profile in profiles:
        if not isinstance(profile, dict) or set(profile) != {"name", "uuid"}:
            die("profiles registry contains an invalid profile entry.")
        name = profile["name"]
        profile_uuid = profile["uuid"]
        if not isinstance(name, str) or not isinstance(profile_uuid, str):
            die("profiles registry contains non-string fields.")
        validate_name(name)
        validate_uuid(profile_uuid)
        if name in names or profile_uuid.lower() in uuids:
            die("profiles registry contains duplicate names or UUIDs.")
        names.add(name)
        uuids.add(profile_uuid.lower())
    return profiles


def load(path: Path) -> list[dict[str, str]]:
    try:
        mode = stat.S_IMODE(path.stat().st_mode)
    except FileNotFoundError:
        die(f"{path} not found.")
    if path.is_symlink() or not path.is_file():
        die(f"{path} must be a regular file.")
    if mode & 0o077:
        die(f"{path} permissions must be 0600. Restrict access with chmod 600; do not weaken permissions to continue.")
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        die(f"Could not read {path}: {exc}")
    return validate_registry(data)


def save(path: Path, profiles: list[dict[str, str]]) -> None:
    if path.parent != Path("."):
        die("Registry file must be in the deployment directory.")
    payload = json.dumps({"version": 1, "profiles": profiles}, indent=2, ensure_ascii=False) + "\n"
    fd, temporary = tempfile.mkstemp(prefix=".profiles.", dir=".")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
        os.chmod(path, 0o600)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def parse_args(argv: list[str]) -> tuple[Path, list[str]]:
    if len(argv) >= 2 and argv[0] == "--file":
        if "/" in argv[1] or argv[1] in {"", ".", ".."}:
            die("Registry file must be in the deployment directory.")
        return Path(argv[1]), argv[2:]
    return Path(DEFAULT_FILE), argv


def main(argv: list[str]) -> None:
    path, args = parse_args(argv)
    if not args:
        die("Usage: profiles.py [--file FILE] ensure UUID | list | get NAME | add NAME UUID | remove NAME | clients")

    command, *values = args
    if command == "ensure":
        if len(values) != 1:
            die("Usage: profiles.py ensure UUID")
        legacy_uuid = validate_uuid(values[0])
        if path.exists():
            load(path)
        else:
            save(path, [{"name": "default", "uuid": legacy_uuid}])
        return

    profiles = load(path)
    if command == "list":
        if values:
            die("Usage: profiles.py list")
        for profile in profiles:
            print(profile["name"])
    elif command == "get":
        if len(values) != 1:
            die("Usage: profiles.py get NAME")
        name = validate_name(values[0])
        for profile in profiles:
            if profile["name"] == name:
                print(profile["uuid"])
                return
        die(f"Profile '{name}' not found. Run 'profiles.py list' locally to inspect available names.")
    elif command == "add":
        if len(values) != 2:
            die("Usage: profiles.py add NAME UUID")
        name = validate_name(values[0])
        profile_uuid = validate_uuid(values[1])
        if any(profile["name"] == name for profile in profiles):
            die(f"Profile '{name}' already exists. Choose a different name or use it with profile.sh show.")
        if any(profile["uuid"].lower() == profile_uuid.lower() for profile in profiles):
            die("Profile UUID already exists.")
        profiles.append({"name": name, "uuid": profile_uuid})
        save(path, profiles)
    elif command == "remove":
        if len(values) != 1:
            die("Usage: profiles.py remove NAME")
        name = validate_name(values[0])
        remaining = [profile for profile in profiles if profile["name"] != name]
        if len(remaining) == len(profiles):
            die(f"Profile '{name}' not found. Run 'profile.sh list' locally to inspect available names.")
        if not remaining:
            die("Cannot revoke the last profile. Add another profile first.")
        save(path, remaining)
    elif command == "clients":
        if values:
            die("Usage: profiles.py clients")
        print(json.dumps([{"id": profile["uuid"], "flow": "xtls-rprx-vision"} for profile in profiles], separators=(",", ":")))
    else:
        die("Unknown command.")


if __name__ == "__main__":
    main(sys.argv[1:])
