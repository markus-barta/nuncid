#!/bin/zsh
set -euo pipefail
repo_dir=${0:A:h:h}
if [[ ${1:-} != calendar || -z ${2:-} || $# != 2 ]]; then
  print -u2 'Usage: scripts/bump-version.sh calendar "release summary"'
  exit 2
fi
exec python3 "$repo_dir/scripts/release-policy.py" reserve "$2"
