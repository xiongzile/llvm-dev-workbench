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
swiftc -swift-version 5 -parse-as-library -target arm64-apple-macosx14.0 \
  -import-objc-header apps/macos/Bridge/LLVMWorkbenchCore.h \
  -L "$app/Contents/Frameworks" -lllvm_dev_core \
  -Xlinker -rpath -Xlinker "$app/Contents/Frameworks" \
  apps/macos/CoreBridge.swift apps/macos/WorkspaceModel.swift \
  tests/macos/OperationFeedbackTests.swift -o build/operation-feedback-tests
test_state_dir=$(mktemp -d "${TMPDIR:-/tmp}/llvm-workbench-feedback.XXXXXX")
trap 'rm -rf "$test_state_dir"' EXIT
LLVM_WORKBENCH_HOME="$test_state_dir" build/operation-feedback-tests
