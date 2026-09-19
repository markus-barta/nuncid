#!/usr/bin/env python3
"""Dry-run the real release-feed pipeline with PUBLIC RFC 8032 fixture keys."""
import base64
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
assert "NUNCID_SPARKLE_PRIVATE_KEY" not in os.environ, "Never pass a production signing key to tests"
SEED = base64.b64encode(bytes.fromhex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")).decode()
PUBLIC = base64.b64encode(bytes.fromhex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")).decode()

with tempfile.TemporaryDirectory(prefix="nuncid-feed-fixture-") as directory:
    fixture = Path(directory)
    for relative in ["scripts/update-feed.py", "scripts/release-policy.py", "scripts/verify-update-signature.swift",
                     "Sources/Nuncid/Resources/Release.json", "VERSION"]:
        destination = fixture / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / relative, destination)
    settings = json.loads((ROOT / "scripts/update-feed.json").read_text())
    settings["public_ed_key"] = PUBLIC
    (fixture / "scripts/update-feed.json").write_text(json.dumps(settings))
    (fixture / ".build/artifacts").mkdir(parents=True)
    (fixture / ".build/artifacts/sparkle").symlink_to(ROOT / ".build/artifacts/sparkle", target_is_directory=True)
    app = fixture / "dist/Nuncid.app"
    shutil.copytree(ROOT / "dist/Nuncid.app", app, symlinks=True)
    plist_path = app / "Contents/Info.plist"
    plist = plistlib.loads(plist_path.read_bytes())
    plist.update(SUPublicEDKey=PUBLIC, SUFeedURL=settings["feed_url"],
                 SURequireSignedFeed=True, SUVerifyUpdateBeforeExtraction=True)
    plist_path.write_bytes(plistlib.dumps(plist))
    # This fixture is never launched or published. Only its archive/feed
    # generation is under test; the real installation test is separate.
    version = (fixture / "VERSION").read_text().strip()
    archive = fixture / "dist" / f"Nuncid-{version}.zip"
    subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive)], check=True)
    fixture_environment = dict(os.environ, NUNCID_SPARKLE_PRIVATE_KEY=SEED)
    command = ["python3", str(fixture / "scripts/update-feed.py")]
    subprocess.run(command + ["create"], env=fixture_environment, check=True)
    # Verification must use the signed archive, without a staged app or key.
    app.rename(fixture / "retained-fixture.bundle")
    subprocess.run(command + ["verify"], check=True)
    # A different source identity must not be accepted for these exact bytes.
    record_path = fixture / "Sources/Nuncid/Resources/Release.json"
    record = json.loads(record_path.read_text())
    record["release_sequence"] += 1
    record_path.write_text(json.dumps(record))
    assert subprocess.run(command + ["verify"], capture_output=True).returncode != 0
    print("Release-feed dry run passed: signed archive/feed, archived trust root, no-key verification, identity mismatch rejection")
