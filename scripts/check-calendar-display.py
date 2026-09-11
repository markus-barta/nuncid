#!/usr/bin/env python3
"""Verify the shipped display design against an immutable public doctrine pin."""
import hashlib
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent.parent
REVISION = "a45fe06250ff5ca3ae5b31d26b4cd16c982ce402"
SIZE = 863
SHA256 = "2fdc8b4f6fcaf71cf3a7c8333e63c0f61bae32ebb8bd334eef0e3f67c59725e0"
COPY = "Sources/Nuncid/Resources/calendar-version-display.json"

subprocess.run(["git", "-C", str(ROOT), "ls-files", "--error-unmatch", COPY], check=True, stdout=subprocess.DEVNULL)
path = ROOT / COPY
assert path.is_file() and not path.is_symlink(), "Display copy must be a regular tracked file"
data = path.read_bytes()
assert len(data) == SIZE and hashlib.sha256(data).hexdigest() == SHA256, "Display design pin mismatch"
pin = subprocess.check_output(["git", "-C", str(ROOT), "ls-files", "--stage", "doctrine"], text=True).split()
assert pin[0] == "160000" and pin[1] == REVISION, "Doctrine gitlink differs from display pin"
doctrine = ROOT / "doctrine"
if (doctrine / ".git").exists():
    head = subprocess.check_output(["git", "-C", str(doctrine), "rev-parse", "HEAD"], text=True).strip()
    assert head == REVISION, "Initialized doctrine has the wrong revision"
    assert data == (doctrine / "lib/calendar-version-display.json").read_bytes(), "Display copy differs from doctrine"
print("Calendar display design revision 3 pin verified")
