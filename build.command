#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h}"
cd "$project_dir"
app_dir="$project_dir/dist/arXiv下载器.app"
mkdir -p "$project_dir/dist" "$project_dir/build"
staging_dir=$(mktemp -d "$project_dir/build/app.XXXXXX")
trap 'rm -rf "$staging_dir"' EXIT
staged_app="$staging_dir/arXiv下载器.app"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
xcrun swiftc -parse-as-library -swift-version 5 -O \
  -target arm64-apple-macosx13.0 \
  -framework AppKit -framework SwiftUI -framework PDFKit \
  Sources/Core.swift Sources/Theme.swift Sources/App.swift \
  -o "$staged_app/Contents/MacOS/ArxivDownloader"
cp Resources/Info.plist "$staged_app/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$staged_app/Contents/Resources/AppIcon.icns"
fi
codesign --force --options runtime --timestamp=none --sign - "$staged_app"
codesign --verify --deep --strict "$staged_app"
xcrun lipo "$staged_app/Contents/MacOS/ArxivDownloader" -verify_arch arm64
rm -rf "$app_dir"
mv "$staged_app" "$app_dir"
print "已构建：$app_dir"
