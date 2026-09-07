#!/bin/zsh
set -euo pipefail
repo_dir=${0:A:h:h}
cd "$repo_dir"
swift build -Xswiftc -warnings-as-errors
"$repo_dir/scripts/check-release-consistency.sh"
python3 "$repo_dir/scripts/test-release-policy.py"
task_tmp_dir=$(mktemp -d)
trap 'rm -rf "$task_tmp_dir"' EXIT
(
  cd "$task_tmp_dir"
  "$repo_dir/.build/debug/Nuncid" --self-test
  "$repo_dir/.build/debug/Nuncid" --inspection-state-self-test
)
print 'Nuncid build, self-tests and calendar release-policy tests passed'
