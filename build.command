#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h}"
cd "$project_dir"
app_dir="$project_dir/dist/arXiv下载器.app"
mkdir -p "$project_dir/dist" "$project_dir/build"
staging_dir=$(mktemp -d "$project_dir/build/app.XXXXXX")
trap 'rm -rf "$staging_dir"' EXIT
staged_app="$staging_dir/arXiv下载器.app"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]
print -r -- "enum BuildVersion { static let current = \"$version\" }" > "$staging_dir/Version.swift"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
xcrun swiftc -parse-as-library -swift-version 5 -O \
  -target arm64-apple-macosx13.0 \
  -framework AppKit -framework SwiftUI -framework PDFKit \
  Sources/Core.swift Sources/PDF.swift Sources/Shared.swift Sources/Theme.swift Sources/Workspace.swift Sources/WorkspaceView.swift Sources/Interaction.swift Sources/SidebarMotion.swift Sources/App.swift \
  -o "$staged_app/Contents/MacOS/ArxivDownloader"
cp Resources/Info.plist "$staged_app/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$staged_app/Contents/Resources/AppIcon.icns"
fi
xcrun swiftc -parse-as-library -swift-version 5 -O \
  -target arm64-apple-macosx13.0 -framework PDFKit \
  Sources/Core.swift Sources/PDF.swift Sources/Shared.swift Sources/CLI.swift "$staging_dir/Version.swift" \
  -o "$staging_dir/arxiv-download"
codesign --force --options runtime --timestamp=none --sign - "$staging_dir/arxiv-download"
codesign --verify --strict "$staging_dir/arxiv-download"
xcrun lipo "$staging_dir/arxiv-download" -verify_arch arm64
test "$("$staging_dir/arxiv-download" --version)" = "$version"
"$staging_dir/arxiv-download" --help > /dev/null
cp "$staging_dir/arxiv-download" "$staged_app/Contents/MacOS/arxiv-download"
# Sign nested code first, then seal the complete app bundle.
codesign --force --options runtime --timestamp=none --sign - "$staged_app"
codesign --verify --deep --strict "$staged_app"
codesign --verify --strict "$staged_app/Contents/MacOS/arxiv-download"
xcrun lipo "$staged_app/Contents/MacOS/ArxivDownloader" -verify_arch arm64
test "$("$staged_app/Contents/MacOS/arxiv-download" --version)" = "$version"
"$staged_app/Contents/MacOS/arxiv-download" --help > /dev/null
cmp "$staging_dir/arxiv-download" "$staged_app/Contents/MacOS/arxiv-download"
rm -rf "$app_dir"
mv "$staged_app" "$app_dir"
mv -f "$staging_dir/arxiv-download" "$project_dir/dist/arxiv-download"
print "已构建：$app_dir"
print "已构建：$project_dir/dist/arxiv-download"
