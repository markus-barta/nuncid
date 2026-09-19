#!/usr/bin/env python3
"""Verify the complete immutable INSPR presentation bundle on every build."""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent.parent
REVISION = "2b8f9dbf160ea666d17d3f8c079712e5f31900b5"
CONFIG_SHA256 = "7843f3515ce329277d2d576000bd60ac410d725b241d502a9a3fecb2533d956d"
MANIFEST_SHA256 = "6fa2f703ba0c24b484fa70820e4ee3879b678417fa1090f6f8b0ee8a8efb6285"
BUNDLE = Path("Sources/Nuncid/Resources/VersioningBundle")


def verify(root=ROOT):
    bundle = root / BUNDLE
    assert bundle.is_dir() and not bundle.is_symlink(), "Bundle must be a regular directory"
    manifest_path = bundle / "manifest.json"
    assert manifest_path.is_file() and not manifest_path.is_symlink(), "Missing regular manifest"
    data = manifest_path.read_bytes()
    assert hashlib.sha256(data).hexdigest() == MANIFEST_SHA256, "Manifest pin mismatch"
    manifest = json.loads(data)
    assert manifest["repository"] == "inspr-at/inspr" and manifest["revision"] == REVISION
    assert manifest["expectedConfigSha256"] == CONFIG_SHA256
    assert manifest["schema"] == "inspr.calendar-version-display.v2"
    expected = {entry["outputPath"] for entry in manifest["files"]} | {"manifest.json"}
    assert {path.name for path in bundle.iterdir()} == expected, "Bundle file set mismatch"
    tracked = set(subprocess.check_output(
        ["git", "-C", str(root), "ls-files", "-z", "--", str(BUNDLE)]
    ).decode().rstrip("\0").split("\0"))
    assert tracked == {str(BUNDLE / name) for name in expected}, "Bundle must be entirely tracked"
    for entry in manifest["files"]:
        name = entry["outputPath"]
        assert Path(name).name == name, "Unsafe bundle filename"
        path = bundle / name
        assert path.is_file() and not path.is_symlink(), "Payload must be a regular file"
        payload = path.read_bytes()
        assert len(payload) == entry["size"] and hashlib.sha256(payload).hexdigest() == entry["sha256"], "Payload digest mismatch"
    assert hashlib.sha256((bundle / "display.json").read_bytes()).hexdigest() == CONFIG_SHA256


if __name__ == "__main__":
    verify()
    print("Pinned INSPR presentation bundle verified")
