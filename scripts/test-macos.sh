#!/bin/bash
set -euo pipefail
project_dir=$(cd "$(dirname "$0")/.." && pwd)
cd "$project_dir"
app="$project_dir/dist/LLVM Workbench.app"
if [[ ! -f "$app/Contents/Frameworks/libllvm_dev_core.dylib" ]]; then
  printf '%s\n' 'Run scripts/build-macos.sh first.' >&2
  exit 1
fi
mkdir -p build
test_app="$project_dir/build/WorkbenchTests.app"
mkdir -p "$test_app/Contents/MacOS" "$test_app/Contents/Resources"
cp -R "$app/Contents/Resources/"*.lproj "$test_app/Contents/Resources/"
cat > "$test_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.llvmworkbench.tests</string>
<key>CFBundleExecutable</key><string>tests</string>
</dict></plist>
PLIST
swiftc -swift-version 5 -parse-as-library -target arm64-apple-macosx14.0 \
  -import-objc-header apps/macos/Bridge/LLVMWorkbenchCore.h \
  -L "$app/Contents/Frameworks" -lllvm_dev_core \
  -Xlinker -rpath -Xlinker "$app/Contents/Frameworks" \
  apps/macos/Localization.swift apps/macos/CoreBridge.swift apps/macos/WorkspaceModel.swift \
  tests/macos/LocalizationTests.swift tests/macos/OperationFeedbackTests.swift \
  -o "$test_app/Contents/MacOS/tests"
test_state_dir=$(mktemp -d "${TMPDIR:-/tmp}/llvm-workbench-feedback.XXXXXX")
trap 'rm -rf "$test_state_dir"' EXIT
LLVM_WORKBENCH_HOME="$test_state_dir" "$test_app/Contents/MacOS/tests"
