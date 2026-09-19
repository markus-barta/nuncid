#!/usr/bin/env python3
"""Run real Sparkle rejection/install/relaunch only on an isolated CI Mac."""
import base64
import functools
import http.server
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import threading
import time
import uuid
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
assert os.environ.get("CI") == "true", "Run on CI, never on the operator's displays"
SIGN = ROOT / ".build/artifacts/sparkle/Sparkle/bin/sign_update"
SEED = base64.b64encode(bytes.fromhex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")).decode()
PUBLIC = base64.b64encode(bytes.fromhex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")).decode()
NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", NS)


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_args):
        pass


def sign(path):
    return subprocess.check_output([str(SIGN), "--ed-key-file", "-", "-p", str(path)], input=SEED, text=True).strip()


def fixture(expect_failure):
    # Keep test bundles out of Trash (AppCleaner may watch it). CI disposes of
    # its isolated machine; no local app or preference domain is touched.
    root = Path(tempfile.mkdtemp(prefix="nuncid-update-integration-"))
    (root / "download").mkdir()
    identifier = "at.markusbarta.nuncid.update-fixture." + uuid.uuid4().hex
    output = root / "result.txt"
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(QuietHandler, directory=str(root / "download")))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}"
    installed = root / "installed/Nuncid.app"
    target = root / "target/Nuncid.app"
    for app, build in [(installed, "1"), (target, "2")]:
        subprocess.run(["ditto", str(ROOT / "dist/Nuncid.app"), str(app)], check=True)
        path = app / "Contents/Info.plist"
        data = plistlib.loads(path.read_bytes())
        data.update(CFBundleIdentifier=identifier, CFBundleVersion=build,
                    SUPublicEDKey=PUBLIC, SUFeedURL=base + "/appcast.xml",
                    SURequireSignedFeed=True, SUVerifyUpdateBeforeExtraction=True,
                    NuncidProbeResultPath=str(output), NuncidProbeExpectsFailure=expect_failure,
                    SUEnableAutomaticChecks=True, SUAutomaticallyUpdate=True, SUAllowsAutomaticUpdates=True)
        if build == "2":
            data.update(NuncidCanonicalVersion="991231235959.0.0", NuncidReleaseSequence=9999)
        path.write_bytes(plistlib.dumps(data))
        subprocess.run(["codesign", "--force", "--sign", "-", "--requirements", f'=designated => identifier "{identifier}"', str(app)], check=True)
    archive = root / "download/Nuncid-fixture.zip"
    subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(target), str(archive)], check=True)
    signature = sign(archive)
    if expect_failure:
        with archive.open("ab") as stream:
            stream.write(b"tampered-after-signing")
    rss = ET.Element("rss", version="2.0")
    item = ET.SubElement(ET.SubElement(rss, "channel"), "item")
    ET.SubElement(item, "title").text = "Synthetic CI upgrade fixture"
    ET.SubElement(item, f"{{{NS}}}version").text = "2"
    ET.SubElement(item, f"{{{NS}}}shortVersionString").text = "991231235959.0.0"
    ET.SubElement(item, "description").text = "\n".join([
        "<!-- nuncid-release-metadata", "version-scheme: inspr-calendar-v2", "version: 991231235959.0.0",
        "release-channel: stable", "release-sequence: 9999", "-->"])
    ET.SubElement(item, "enclosure", {"url": base + "/Nuncid-fixture.zip", "type": "application/octet-stream",
                                    "length": str(archive.stat().st_size), f"{{{NS}}}edSignature": signature})
    feed = root / "download/appcast.xml"
    feed.write_bytes(ET.tostring(rss, encoding="utf-8", xml_declaration=True) + b"\n")
    sign(feed)
    log_path = ROOT / ".build" / ("update-rejection.log" if expect_failure else "update-upgrade.log")
    with log_path.open("w") as log:
        process = subprocess.Popen([str(installed / "Contents/MacOS/Nuncid")], stdout=log, stderr=log)
        try:
            expected = "rejected;installed-app-preserved" if expect_failure else "installed;preferences-preserved"
            observed = ""
            for _ in range(120):
                if output.exists():
                    observed = output.read_text()
                    if observed == expected:
                        break
                    if observed not in ["", "ready;waiting-for-user"]:
                        raise AssertionError(f"Sparkle integration: {observed}; inspect {log_path}")
                time.sleep(1)
            assert observed == expected, f"Sparkle integration timed out: {observed}; inspect {log_path}"
            installed_build = plistlib.loads((installed / "Contents/Info.plist").read_bytes())["CFBundleVersion"]
            assert installed_build == ("1" if expect_failure else "2")
            print(expected)
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=10)
            server.shutdown()


subprocess.run([str(ROOT / "scripts/package-app.sh"), "debug"], check=True)
preview = ROOT / ".build/update-settings.png"
process = subprocess.Popen([str(ROOT / ".build/debug/Nuncid"), "--settings-updates-probe", "--settings-capture-probe", str(preview)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    for _ in range(50):
        if preview.exists():
            break
        time.sleep(0.2)
    assert preview.exists(), "Updates settings preview failed"
finally:
    process.terminate()
    process.wait(timeout=10)
fixture(True)
fixture(False)
print("Real Sparkle signature rejection, staging, user-triggered install, relaunch and preference preservation passed")
