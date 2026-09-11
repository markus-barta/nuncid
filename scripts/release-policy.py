#!/usr/bin/env python3
"""NUNCID-58: explicit calendar reservation, bundle mapping and release sets.
VERSION is canonical. Release.json is its checked runtime metadata mirror.
No build node derives a coordinate from its own clock.
"""
import argparse
import datetime as dt
import hashlib
import json
import plistlib
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent
RECORD = Path("Sources/Nuncid/Resources/Release.json")
SCHEME_V1 = "inspr-calendar-v1"
SCHEME = "inspr-calendar-v2"
LAST_V1 = "26.09.11.10.11.21"
FIRST_V2_SEQUENCE = 26


def calendar(value):
    if not re.fullmatch(r"[0-9]{2}(?:\.[0-9]{2}){2}(?:(?:\.[0-9]{2}){3})?", value):
        raise ValueError("Noncanonical calendar coordinate")
    fields = list(map(int, value.split(".")))
    return dt.datetime(2000 + fields[0], *fields[1:], tzinfo=dt.timezone.utc)


def calendar_v2(value):
    if not re.fullmatch(r"[1-9][0-9]{11}\.0\.0", value):
        raise ValueError("Noncanonical calendar v2 coordinate")
    return calendar(".".join(value[index:index + 2] for index in range(0, 12, 2)))


def bundle_version_v2(value):
    return bundle_version(calendar_v2(value).strftime("%y.%m.%d.%H.%M.%S"))


def canonical_version_v2(external):
    legacy = canonical_version(external)
    if len(legacy.split(".")) != 6:
        raise ValueError("Calendar v2 requires second precision")
    value = legacy.replace(".", "") + ".0.0"
    calendar_v2(value)
    return value


def bundle_version(value):
    date = calendar(value)
    # CFBundleShortVersionString requires three numeric components. The date
    # and precision bit are lossless; zero is short form, 1..86400 long form.
    clock = 0 if len(value.split(".")) == 3 else 1 + date.hour * 3600 + date.minute * 60 + date.second
    return f"{date.year}.{date.month * 100 + date.day}.{clock}"


def canonical_version(external):
    if not re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", external):
        raise ValueError("Noncanonical bundle version")
    year, monthday, clock = map(int, external.split("."))
    if not 2000 <= year <= 2099 or not 0 <= clock <= 86400:
        raise ValueError("Bundle version out of range")
    base = dt.datetime(year, monthday // 100, monthday % 100, tzinfo=dt.timezone.utc)
    value = base.strftime("%y.%m.%d")
    if clock:
        value += (base + dt.timedelta(seconds=clock - 1)).strftime(".%H.%M.%S")
    if bundle_version(value) != external:
        raise ValueError("Ambiguous mapping")
    return value


def load(root=ROOT):
    raw = (root / "VERSION").read_text()
    if not raw.endswith("\n") or raw.count("\n") != 1:
        raise ValueError("VERSION must contain exactly one canonical line")
    version = raw[:-1]
    record = json.loads((root / RECORD).read_text())
    if record["version"] != version or record["release_channel"] != "stable":
        raise ValueError("Version/channel metadata mismatch")
    if any(candidate["version"] == version for candidate in record.get("retired_calendar_candidates", [])):
        raise ValueError("Retired candidate coordinates cannot be reused")
    sequence = record["release_sequence"]
    if type(sequence) is not int or sequence < 1:
        raise ValueError("Invalid release sequence")
    if record["version_scheme"] == SCHEME:
        value = calendar_v2(version)
        if record["bundle_short_version"] != bundle_version_v2(version):
            raise ValueError("Invalid macOS v2 mapping")
        if (record["last_legacy_version"] != LAST_V1
                or record.get("legacy_version_scheme") != SCHEME_V1
                or record["first_calendar_sequence"] != FIRST_V2_SEQUENCE):
            raise ValueError("Unknown v2 migration anchor")
        first = calendar_v2(record["first_calendar_version"])
        if (first <= calendar(LAST_V1) or sequence < FIRST_V2_SEQUENCE or value < first
                or ((sequence == FIRST_V2_SEQUENCE) != (version == record["first_calendar_version"]))):
            raise ValueError("Calendar v2 coordinate contradicts migration anchor")
    elif record["version_scheme"] == SCHEME_V1:
        calendar(version)
        if len(version.split(".")) != 6:
            raise ValueError("Nuncid reserves long form for every release")
        if record["bundle_short_version"] != bundle_version(version):
            raise ValueError("Invalid macOS mapping")
        if record["last_legacy_version"] != "1.2.3" or record["first_calendar_sequence"] != 20:
            raise ValueError("Unknown migration anchor")
        first = calendar(record["first_calendar_version"])
        if sequence < 20 or calendar(version) < first or ((sequence == 20) != (version == record["first_calendar_version"])):
            raise ValueError("Calendar coordinate contradicts migration anchor")
        if sequence >= FIRST_V2_SEQUENCE or calendar(version) > calendar(LAST_V1):
            raise ValueError("Calendar v1 exceeds its immutable migration boundary")
    elif record["version_scheme"] == "legacy":
        if version != "1.2.3" or sequence != 19 or record["bundle_short_version"] != version:
            raise ValueError("Only the immutable final legacy anchor is accepted")
    else:
        raise ValueError("Unknown version scheme")
    return record


def reserve(summary, root=ROOT, now=None):
    old = load(root)
    now = now or dt.datetime.now(dt.timezone.utc)
    if now.utcoffset() != dt.timedelta(0):
        raise ValueError("Reservation must use UTC")
    version = now.strftime("%y%m%d%H%M%S") + ".0.0"
    if not 2010 <= now.year <= 2099:
        raise ValueError("Unsupported UTC year")
    if old["version_scheme"] not in (SCHEME_V1, SCHEME):
        raise ValueError("Migrate only from the approved calendar-v1 anchor")
    if old["version_scheme"] == SCHEME_V1 and (old["version"] != LAST_V1 or old["release_sequence"] != FIRST_V2_SEQUENCE - 1):
        raise ValueError("Migration requires the exact final v1 anchor")
    previous = calendar_v2(old["version"]) if old["version_scheme"] == SCHEME else calendar(old["version"])
    if calendar_v2(version) <= previous:
        raise ValueError("Same-second/older reservation: wait for a later UTC second")
    changelog = (root / "CHANGELOG.md").read_text()
    readme = (root / "README.md").read_text()
    if f"## [{version}]" in changelog or list((root / "dist").glob(f"*{version}*")):
        raise ValueError("Coordinate already reserved")
    tag = subprocess.run(["git", "-C", str(root), "show-ref", "--verify", "--quiet", f"refs/tags/v{version}"], check=False)
    if tag.returncode not in (1,):
        raise ValueError("Tag exists or tag inventory unavailable")
    if changelog.count("## [Unreleased]\n") != 1 or f"release-{old['version']}-" not in readme:
        raise ValueError("Missing release headings/badge")
    record = dict(old, version_scheme=SCHEME, version=version,
                  release_sequence=old["release_sequence"] + 1,
                  bundle_short_version=bundle_version_v2(version),
                  legacy_version_scheme=SCHEME_V1,
                  last_legacy_version=LAST_V1, first_calendar_sequence=FIRST_V2_SEQUENCE,
                  first_calendar_version=old["first_calendar_version"] if old["version_scheme"] == SCHEME else version)
    if old["version_scheme"] == SCHEME_V1:
        record["previous_migrations"] = [{key: old[key] for key in ["last_legacy_version", "first_calendar_version", "first_calendar_sequence"]} | {"legacy_version_scheme": "legacy", "version_scheme": SCHEME_V1}]
    # All validation precedes writes. Git records this as one reservation
    # transaction; interrupted writes fail load() and must be recovered first.
    changelog = changelog.replace("## [Unreleased]\n", f"## [Unreleased]\n\n## [{version}] - {now:%Y-%m-%d}\n\n- {summary}\n", 1)
    readme = readme.replace(f"release-{old['version']}-", f"release-{version}-").replace(f"Latest release {old['version']}", f"Latest release {version}").replace(f"-{old['version']}.png", f"-{version}.png")
    (root / RECORD).write_text(json.dumps(record, indent=2) + "\n")
    (root / "CHANGELOG.md").write_text(changelog)
    (root / "README.md").write_text(readme)
    (root / "VERSION").write_text(version + "\n")
    return version


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def create_manifest(root=ROOT):
    record = load(root)
    version = record["version"]
    archive = root / "dist" / f"Nuncid-{version}.zip"
    checksum = archive.with_suffix(".sha256")
    with checksum.open("x") as output:
        output.write(f"{digest(archive)}  {archive.name}\n")
    git = lambda *args: subprocess.check_output(["git", "-C", str(root), *args], text=True).strip()
    if git("diff", "HEAD", "--"):
        raise ValueError("Release candidates require a committed source tree")
    locks = {str(path.relative_to(root)): digest(path) for path in [root / "Package.resolved", root / "flake.lock"] if path.exists()}
    app = root / "dist/Nuncid.app"
    plist = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    arch = subprocess.check_output(["lipo", "-archs", str(app / "Contents/MacOS/Nuncid")], text=True).strip().replace(" ", "+")
    variant = plist["NuncidSigningMode"]
    coordinate = f"app/zip/macos/{arch}/{variant}"
    manifest = dict(record, source_commit=git("rev-parse", "HEAD"), source_tree=git("rev-parse", "HEAD^{tree}"),
                    bundle_build_version=plist["CFBundleVersion"],
                    dependency_locks=locks, doctrine_commit=git("rev-parse", "HEAD:doctrine"),
                    artifacts=[
                        {"coordinate": coordinate, "file": archive.name, "sha256": digest(archive)},
                        {"coordinate": f"checksum/sha256/macos/{arch}/{variant}", "file": checksum.name, "sha256": digest(checksum)}])
    path = root / "dist" / f"Nuncid-{version}.release-set.json"
    with path.open("x") as output:
        output.write(json.dumps(manifest, indent=2) + "\n")
    return path


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["validate", "reserve", "field", "manifest", "metadata"])
    parser.add_argument("value", nargs="?")
    args = parser.parse_args()
    try:
        if args.command == "reserve":
            if not args.value or "\n" in args.value:
                raise ValueError("Provide a one-line release summary")
            print(reserve(args.value))
        elif args.command == "manifest":
            print(create_manifest())
        else:
            record = load()
            if args.command == "field":
                print(record[args.value])
            elif args.command == "metadata":
                print("<!-- nuncid-release-metadata")
                for field in ["version_scheme", "version", "release_channel", "release_sequence"]:
                    print(f"{field.replace('_', '-')}: {record[field]}")
                print("-->")
            else:
                print(record["version"])
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Release policy: {error}\n")
