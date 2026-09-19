#!/usr/bin/env python3
"""Create or verify a signed Sparkle feed bound to the exact release archive."""
import base64
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)
SPEC = importlib.util.spec_from_file_location("release_policy", ROOT / "scripts/release-policy.py")
POLICY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(POLICY)


def config():
    value = json.loads((ROOT / "scripts/update-feed.json").read_text())
    if value["feed_url"] != "https://github.com/markus-barta/nuncid/releases/latest/download/appcast.xml":
        raise ValueError("Unexpected feed endpoint")
    if len(base64.b64decode(value["public_ed_key"] or "", validate=True)) != 32:
        raise ValueError("Configure the approved public update-signing key before packaging a release")
    return value


def verifier():
    path = ROOT / ".build/verify-update-signature"
    subprocess.run(["swiftc", str(ROOT / "scripts/verify-update-signature.swift"), "-o", str(path)], check=True)
    return path


def verify_signature(tool, kind, path, key, signature=None):
    args = [str(tool), kind, str(path), key]
    if signature is not None:
        args.append(signature)
    subprocess.run(args, check=True)


def sign(path):
    # Never put key material in argv, files, logs or exceptions. CI supplies it
    # only to this step from the repository's dedicated Actions secret.
    key = os.environ.get("NUNCID_SPARKLE_PRIVATE_KEY")
    if not key:
        raise ValueError("NUNCID_SPARKLE_PRIVATE_KEY is required to sign this release")
    tool = ROOT / ".build/artifacts/sparkle/Sparkle/bin/sign_update"
    result = subprocess.run([str(tool), "--ed-key-file", "-", "-p", str(path)],
                            input=key, text=True, capture_output=True)
    if result.returncode:
        raise ValueError("Sparkle signing failed; diagnostic output withheld to protect key material")
    return result.stdout.strip()


def archive_info(record):
    archive = ROOT / "dist" / f'Nuncid-{record["version"]}.zip'
    plist = plistlib.loads((ROOT / "dist/Nuncid.app/Contents/Info.plist").read_bytes())
    if plist["NuncidCanonicalVersion"] != record["version"]:
        raise ValueError("Packaged version mismatch")
    return archive, plist


def create():
    settings = config()
    record = POLICY.load()
    archive, plist = archive_info(record)
    feed = ROOT / "dist/appcast.xml"
    if feed.exists():
        raise ValueError("Appcast already exists; preserve the immutable candidate")
    signature = sign(archive)
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError("Invalid archive signature")
    rss = ET.Element("rss", version="2.0")
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "Nuncid updates"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f'Nuncid {record["version"]}'
    ET.SubElement(item, f"{{{SPARKLE}}}version").text = plist["CFBundleVersion"]
    ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = record["version"]
    ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = "13.0.0"
    # Current release packaging produces an Apple-silicon app. Do not offer it
    # to Intel installations merely because Sparkle itself is universal.
    arch = subprocess.check_output(["lipo", "-archs", str(ROOT / "dist/Nuncid.app/Contents/MacOS/Nuncid")], text=True).strip()
    if arch != "arm64":
        raise ValueError("Review appcast hardware requirements for this architecture")
    ET.SubElement(item, f"{{{SPARKLE}}}hardwareRequirements").text = "arm64"
    ET.SubElement(item, "description").text = subprocess.check_output(
        [sys.executable, str(ROOT / "scripts/release-policy.py"), "metadata"], text=True)
    ET.SubElement(item, "enclosure", {
        "url": f'https://github.com/markus-barta/nuncid/releases/download/v{record["version"]}/{archive.name}',
        "type": "application/octet-stream", "length": str(archive.stat().st_size),
        f"{{{SPARKLE}}}edSignature": signature})
    with feed.open("xb") as output:
        output.write(ET.tostring(rss, encoding="utf-8", xml_declaration=True) + b"\n")
    sign(feed)
    verify(settings)


def verify(settings=None):
    settings = settings or config()
    record = POLICY.load()
    archive, plist = archive_info(record)
    feed = ROOT / "dist/appcast.xml"
    tool = verifier()
    verify_signature(tool, "feed", feed, settings["public_ed_key"])
    item = ET.parse(feed).getroot().find("channel/item")
    if item is None or len(ET.parse(feed).getroot().findall("channel/item")) != 1:
        raise ValueError("Expected exactly one immutable release in the appcast")
    enclosure = item.find("enclosure")
    expected_url = f'https://github.com/markus-barta/nuncid/releases/download/v{record["version"]}/{archive.name}'
    if enclosure is None or enclosure.get("url") != expected_url or enclosure.get("length") != str(archive.stat().st_size):
        raise ValueError("Appcast archive mismatch")
    if item.findtext(f"{{{SPARKLE}}}version") != plist["CFBundleVersion"] or item.findtext(f"{{{SPARKLE}}}shortVersionString") != record["version"]:
        raise ValueError("Appcast version mismatch")
    if plist.get("SUPublicEDKey") != settings["public_ed_key"] or not plist.get("SURequireSignedFeed") or not plist.get("SUVerifyUpdateBeforeExtraction"):
        raise ValueError("Installed trust root mismatch")
    verify_signature(tool, "archive", archive, settings["public_ed_key"], enclosure.get(f"{{{SPARKLE}}}edSignature"))


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["create"]:
            create()
        elif sys.argv[1:] == ["verify"]:
            verify()
        elif sys.argv[1:] == ["config"]:
            config()
        else:
            raise ValueError("Use create, verify or config")
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
        # No child stderr/stdout or environment values are interpolated here.
        print(f"Update feed operation failed ({type(error).__name__}); check public configuration and signing availability.", file=sys.stderr)
        sys.exit(1)
