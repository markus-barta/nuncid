#!/usr/bin/env python3
"""Exercise Sparkle signing with the PUBLIC RFC 8032 test seed, never live keys."""
import base64
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
SIGN = ROOT / ".build/artifacts/sparkle/Sparkle/bin/sign_update"
# RFC 8032 section 7.1 TEST 1. Public test material, deliberately not a secret.
SEED = base64.b64encode(bytes.fromhex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")).decode()
PUBLIC = base64.b64encode(bytes.fromhex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")).decode()

with tempfile.TemporaryDirectory(prefix="nuncid-signature-test-") as temp:
    root = Path(temp)
    verifier = root / "verify"
    subprocess.run(["swiftc", str(ROOT / "scripts/verify-update-signature.swift"), "-o", str(verifier)], check=True)
    archive = root / "fixture.zip"
    archive.write_bytes(b"Synthetic test archive\n")
    signature = subprocess.check_output([str(SIGN), "--ed-key-file", "-", "-p", str(archive)], input=SEED, text=True).strip()
    subprocess.run([str(verifier), "archive", str(archive), PUBLIC, signature], check=True)
    archive.write_bytes(b"Tampered archive\n")
    assert subprocess.run([str(verifier), "archive", str(archive), PUBLIC, signature], capture_output=True).returncode != 0
    feed = root / "appcast.xml"
    feed.write_text('<?xml version="1.0"?><rss version="2.0"><channel><title>Fixture</title></channel></rss>\n')
    subprocess.run([str(SIGN), "--ed-key-file", "-", "-p", str(feed)], input=SEED, text=True, check=True)
    subprocess.run([str(verifier), "feed", str(feed), PUBLIC], check=True)
    original = feed.read_bytes()
    for changed in [original.replace(b"Fixture", b"Altered"), original + b"untrusted tail", original.split(b"<!-- sparkle-signatures:")[0]]:
        feed.write_bytes(changed)
        assert subprocess.run([str(verifier), "feed", str(feed), PUBLIC], capture_output=True).returncode != 0
    print("Sparkle archive/feed signatures and tamper rejection passed")
