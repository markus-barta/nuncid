#!/bin/zsh
set -euo pipefail

repo_dir=${0:A:h:h}
version=$(tr -d '[:space:]' < "$repo_dir/VERSION")
app="$repo_dir/dist/Nuncid.app"
archive="$repo_dir/dist/Nuncid-$version.zip"
plist="$app/Contents/Info.plist"

"$repo_dir/scripts/check-release-consistency.sh"
[[ -d "$app" ]] || { print -u2 "Missing $app"; exit 1; }
[[ -f "$archive" ]] || { print -u2 "Missing $archive"; exit 1; }

bundle_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
[[ "$bundle_version" == "$(python3 "$repo_dir/scripts/release-policy.py" field bundle_short_version)" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :NuncidCanonicalVersion' "$plist")" == "$version" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :NuncidVersionScheme' "$plist")" == "$(python3 "$repo_dir/scripts/release-policy.py" field version_scheme)" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :NuncidReleaseChannel' "$plist")" == stable ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :NuncidReleaseSequence' "$plist")" == "$(python3 "$repo_dir/scripts/release-policy.py" field release_sequence)" ]]
cmp "$repo_dir/Sources/Nuncid/Resources/Release.json" "$app/Contents/Resources/Release.json"
codesign --verify --deep --strict "$app"
unzip -tq "$archive" >/dev/null

signing_mode=$(/usr/libexec/PlistBuddy -c 'Print :NuncidSigningMode' "$plist")
signature_details=$(codesign -dv --verbose=4 "$app" 2>&1)
case "$signing_mode" in
  ad-hoc)
    [[ "$signature_details" == *$'\nSignature=adhoc\n'* ]] || {
      print -u2 'Bundle declares ad-hoc signing but its signature disagrees.'
      exit 1
    }
    [[ "${NUNCID_EXPECT_NOTARIZED:-0}" != 1 ]] || {
      print -u2 'An ad-hoc build cannot satisfy NUNCID_EXPECT_NOTARIZED=1.'
      exit 1
    }
    ;;
  developer-id)
    [[ "$signature_details" == *$'\nAuthority=Developer ID Application:'* ]] || {
      print -u2 'Bundle declares Developer ID signing but its signature disagrees.'
      exit 1
    }
    if [[ "${NUNCID_EXPECT_NOTARIZED:-0}" == 1 ]]; then
      xcrun stapler validate "$app"
    fi
    ;;
  *) print -u2 "Unknown NuncidSigningMode: $signing_mode"; exit 1 ;;
esac

self_test_dir=$(mktemp -d)
trap 'rm -rf "$self_test_dir"' EXIT
python3 - "$repo_dir" "$version" <<'PY'
import hashlib, json, pathlib, subprocess, sys, zipfile
root, version = pathlib.Path(sys.argv[1]), sys.argv[2]
manifest = json.loads((root / 'dist' / f'Nuncid-{version}.release-set.json').read_text())
record = json.loads((root / 'Sources/Nuncid/Resources/Release.json').read_text())
assert all(manifest.get(key) == value for key, value in record.items()), 'Manifest identity mismatch'
assert manifest['source_tree'] == subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD^{tree}'], text=True).strip()
assert len(manifest['artifacts']) == 2 and len({item['coordinate'] for item in manifest['artifacts']}) == 2
for item in manifest['artifacts']:
    assert pathlib.Path(item['file']).name == item['file'], 'Unsafe artifact name'
    assert hashlib.sha256((root / 'dist' / item['file']).read_bytes()).hexdigest() == item['sha256'], 'Artifact digest mismatch'
with zipfile.ZipFile(root / 'dist' / f'Nuncid-{version}.zip') as archive:
    for name in archive.namelist():
        assert not name.startswith('/') and '..' not in pathlib.PurePosixPath(name).parts, 'Unsafe archive path'
PY
ditto -x -k "$archive" "$self_test_dir"
extracted="$self_test_dir/Nuncid.app"
codesign --verify --deep --strict "$extracted"
python3 - "$app" "$extracted" <<'PY'
import hashlib, pathlib, sys
def inventory(directory):
    root = pathlib.Path(directory)
    return {str(path.relative_to(root)): ('link', str(path.readlink())) if path.is_symlink() else ('file', hashlib.sha256(path.read_bytes()).hexdigest()) for path in root.rglob('*') if path.is_symlink() or path.is_file()}
assert inventory(sys.argv[1]) == inventory(sys.argv[2]), 'Archive is not the verified app'
PY
(
  cd "$self_test_dir"
  "$extracted/Contents/MacOS/Nuncid" --self-test
)

print -r -- "Verified Nuncid $version package ($signing_mode signing)"
