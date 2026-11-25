#!/bin/zsh
# Runs the Swift tests and the TypeScript checks. Works with just the Command Line Tools
# (which ship Swift Testing outside the default search paths).
set -euo pipefail
cd "$(dirname "$0")"
bun check src/typescript/index.ts
bun fmt --check .
swift format lint --strict -r src/swift tests/swift
DEV=/Library/Developer/CommandLineTools/Library/Developer
FLAGS=()
if [[ -d "$DEV/Frameworks/Testing.framework" ]]; then
  FLAGS=(
    -Xswiftc -F -Xswiftc "$DEV/Frameworks" -Xlinker -F -Xlinker "$DEV/Frameworks"
    -Xlinker -rpath -Xlinker "$DEV/Frameworks" -Xlinker -rpath -Xlinker "$DEV/usr/lib"
  )
  [[ ! -d "$DEV/Frameworks/_Testing_Foundation.framework/Modules" ]] && FLAGS+=(
    -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays
  )
fi
swift test "${FLAGS[@]}" 2>&1 | grep -E "✔|✘|error:|Test run"
