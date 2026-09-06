#!/bin/zsh
set -euo pipefail

repo_dir=${0:A:h:h}
version=$(tr -d '[:space:]' < "$repo_dir/VERSION")
archive="$repo_dir/dist/Nuncid-$version.zip"
temporary_archive="$repo_dir/dist/.Nuncid-$version.$$.zip"
notary_profile=${NUNCID_NOTARY_PROFILE:-}
signing_identity=${NUNCID_SIGNING_IDENTITY:--}

trap 'rm -f "$temporary_archive"' EXIT
python3 "$repo_dir/scripts/release-policy.py" validate >/dev/null
[[ ! -e "$archive" && ! -e "$repo_dir/dist/Nuncid-$version.release-set.json" && ! -e "$repo_dir/dist/Nuncid-$version.sha256" ]] || {
  print -u2 'This artifact coordinate already exists. Verify/reuse its exact bytes, or reserve a later calendar coordinate.'
  exit 1
}
git -C "$repo_dir" diff --quiet HEAD -- || { print -u2 'Commit the source tree before creating a release candidate.'; exit 1; }
[[ -z "$(git -C "$repo_dir" ls-files --others --exclude-standard -- Sources scripts docs/screenshots Package.swift VERSION CHANGELOG.md README.md)" ]] || {
  print -u2 'Untracked release inputs must be reviewed and committed before packaging.'; exit 1
}
if [[ -n "$notary_profile" && "$signing_identity" == "-" ]]; then
  print -u2 'NUNCID_NOTARY_PROFILE requires NUNCID_SIGNING_IDENTITY.'
  exit 1
fi
"$repo_dir/scripts/package-app.sh" release
ditto -c -k --sequesterRsrc --keepParent "$repo_dir/dist/Nuncid.app" "$temporary_archive"
if [[ -n "$notary_profile" ]]; then
  xcrun notarytool submit "$temporary_archive" --keychain-profile "$notary_profile" --wait
  xcrun stapler staple "$repo_dir/dist/Nuncid.app"
  xcrun stapler validate "$repo_dir/dist/Nuncid.app"
  rm -f "$temporary_archive"
  ditto -c -k --sequesterRsrc --keepParent "$repo_dir/dist/Nuncid.app" "$temporary_archive"
  print -r -- 'Developer ID build notarized and ticket stapled.' >&2
fi
# No clobber, even if a second packager raced the initial collision check.
ln "$temporary_archive" "$archive" || { print -u2 'Artifact reservation collision.'; exit 1; }
python3 "$repo_dir/scripts/release-policy.py" manifest
echo "$archive"
