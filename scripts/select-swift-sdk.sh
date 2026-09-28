#!/bin/zsh
# Print an SDK path when the default macOS SDK cannot be compiled here.
# Empty output means the default SDK is usable.
#
# The macOS 27 SDK declares SwiftUI @State as SwiftUIMacros.StateMacro.
# Command Line Tools ship that SDK without libSwiftUIMacros.dylib. Xcode
# includes the plugin. When it is missing, use the newest installed SDK
# that still declares State as a type.
set -euo pipefail
if [[ -n ${SDKROOT:-} ]]; then
  exit 0
fi
developer=$(xcode-select -p)
if [[ -e "$developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ]]; then
  exit 0
fi
default_sdk=$(xcrun --sdk macosx --show-sdk-path)
default_sdk=$(cd "$default_sdk" && pwd -P)
sdks_dir=${default_sdk:h}

state_is_macro() {
  local sdk=$1
  local -a files
  files=(${sdk}/System/Library/Frameworks/SwiftUICore.framework/Modules/SwiftUICore.swiftmodule/*-apple-macos.swiftinterface(N))
  (( ${#files} )) || return 1
  [[ "$(<"$files[1]")" == *'type: "StateMacro"'* ]]
}

if ! state_is_macro "$default_sdk"; then
  exit 0
fi

fallback=
while IFS= read -r name; do
  [[ -n $name ]] || continue
  path=$sdks_dir/$name
  [[ -d $path && ! -L $path ]] || continue
  path=$(cd "$path" && pwd -P)
  [[ $path == "$default_sdk" ]] && continue
  state_is_macro "$path" && continue
  fallback=$path
done < <(cd "$sdks_dir" && print -l MacOSX*.sdk(N) | sort -V)

if [[ -z $fallback ]]; then
  print -u2 'The default macOS SDK needs SwiftUIMacros, and this toolchain does not include that plugin. Install Xcode, or keep an older macOS SDK beside it.'
  exit 1
fi
print -r -- "$fallback"
