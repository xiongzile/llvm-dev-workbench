#!/bin/bash
set -euo pipefail
project_dir=$(cd "$(dirname "$0")/.." && pwd)
cd "$project_dir"
cargo build --release --workspace
app="$project_dir/dist/LLVM Workbench.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources"
cp -R apps/macos/Resources/*.lproj "$app/Contents/Resources/"
swift scripts/make-icon.swift "$project_dir/build/AppIcon.iconset"
iconutil -c icns "$project_dir/build/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
cp target/release/libllvm_dev_core.dylib "$app/Contents/Frameworks/"
install_name_tool -id '@rpath/libllvm_dev_core.dylib' "$app/Contents/Frameworks/libllvm_dev_core.dylib"
swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macosx14.0 \
  -import-objc-header apps/macos/Bridge/LLVMWorkbenchCore.h \
  -L "$app/Contents/Frameworks" -lllvm_dev_core \
  -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
  apps/macos/*.swift -o "$app/Contents/MacOS/LLVMWorkbench"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LLVMWorkbench</string>
<key>CFBundleIdentifier</key><string>dev.llvmworkbench.mac</string>
<key>CFBundleName</key><string>LLVM Workbench</string>
<key>CFBundleDisplayName</key><string>LLVM Workbench</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.3</string>
<key>CFBundleVersion</key><string>4</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>LLVM Workbench — local preview</string>
</dict></plist>
PLIST
codesign --force --sign - "$app/Contents/Frameworks/libllvm_dev_core.dylib"
codesign --force --deep --sign - "$app"
printf 'Built: %s\n' "$app"
