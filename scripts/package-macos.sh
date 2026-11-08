#!/bin/bash
set -euo pipefail
project_dir=$(cd "$(dirname "$0")/.." && pwd)
cd "$project_dir"
app="$project_dir/dist/LLVM Workbench.app"
if [[ ! -f "$app/Contents/MacOS/LLVMWorkbench" ]]; then
  printf '%s\n' 'Run scripts/build-macos.sh first.' >&2
  exit 1
fi
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
archive="LLVM-Workbench-$version-macos-arm64.zip"
codesign --verify --deep --strict "$app"
ditto -c -k --sequesterRsrc --keepParent "$app" "$project_dir/dist/$archive"
(
  cd "$project_dir/dist"
  shasum -a 256 "$archive" > "$archive.sha256"
)
verification_dir=$(mktemp -d "${TMPDIR:-/tmp}/llvm-workbench-package.XXXXXX")
trap 'rm -rf "$verification_dir"' EXIT
ditto -x -k "$project_dir/dist/$archive" "$verification_dir"
codesign --verify --deep --strict "$verification_dir/LLVM Workbench.app"
cmp "$app/Contents/MacOS/LLVMWorkbench" "$verification_dir/LLVM Workbench.app/Contents/MacOS/LLVMWorkbench"
cmp "$app/Contents/Frameworks/libllvm_dev_core.dylib" "$verification_dir/LLVM Workbench.app/Contents/Frameworks/libllvm_dev_core.dylib"
printf 'Verified release archive: %s\n' "$project_dir/dist/$archive"
