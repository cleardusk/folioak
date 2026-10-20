#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h}"
cd "$project_dir"
app_dir="$project_dir/dist/Folioak.app"
mkdir -p "$project_dir/dist" "$project_dir/build"
python3 Tools/prepare-media.py
xcrun swift Tools/MakeIcon.swift Resources/FolioakIcon.png build/Folioak.iconset
iconutil -c icns build/Folioak.iconset -o Resources/AppIcon.icns
staging_dir=$(mktemp -d "$project_dir/build/app.XXXXXX")
trap 'rm -rf "$staging_dir"' EXIT
staged_app="$staging_dir/Folioak.app"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]
print -r -- "enum BuildVersion { static let current = \"$version\" }" > "$staging_dir/Version.swift"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
xcrun swiftc -parse-as-library -swift-version 5 -O \
  -target arm64-apple-macosx13.0 \
  -framework AppKit -framework SwiftUI -framework PDFKit -framework QuickLookThumbnailing -framework Security \
  Sources/Messages.swift Sources/BrowserAuthentication.swift Sources/DownloadError.swift Sources/Core.swift Sources/PDF.swift Sources/Media.swift Sources/Files.swift Sources/Douyin.swift Sources/Shared.swift Sources/AssetNaming.swift Sources/Localization.swift Sources/Theme.swift Sources/Workspace.swift Sources/WorkspacePersistence.swift Sources/Library.swift Sources/AssetRename.swift Sources/Shortcuts.swift Sources/LibraryPresentation.swift Sources/WorkspaceView.swift Sources/Interaction.swift Sources/FileInformation.swift Sources/MediaThumbnail.swift Sources/SidebarMotion.swift Sources/WorkspaceBrand.swift Sources/BrowserAuthenticationSettings.swift Sources/Updates.swift Sources/QuickDownload.swift Sources/AssetNamingSettings.swift Sources/InteractionTrace.swift Sources/InteractionTraceSettings.swift Sources/PreferencesPages.swift Sources/SmartInput.swift Sources/SmartResolver.swift Sources/SmartSettings.swift Sources/SmartDownload.swift Sources/SmartInputView.swift Sources/App.swift \
  -o "$staged_app/Contents/MacOS/FolioakApp"
strip "$staged_app/Contents/MacOS/FolioakApp"
cp Resources/Info.plist "$staged_app/Contents/Info.plist"
cp -R Resources/en.lproj Resources/zh-Hans.lproj "$staged_app/Contents/Resources/"
cp LICENSE "$staged_app/Contents/Resources/LICENSE"
cp Resources/FolioakGlyph.png "$staged_app/Contents/Resources/FolioakGlyph.png"
cp -R build/media-tools "$staged_app/Contents/Resources/media-tools"
# Prepared tools, nested Python framework and shared libraries are already signed.
"$staged_app/Contents/Resources/media-tools/qjs" --version
"$staged_app/Contents/Resources/media-tools/yt-dlp" --ignore-config --version
"$staged_app/Contents/Resources/media-tools/ffmpeg" -version > /dev/null
"$staged_app/Contents/Resources/media-tools/ffprobe" -version > /dev/null
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$staged_app/Contents/Resources/AppIcon.icns"
fi
xcrun swiftc -parse-as-library -swift-version 5 -O \
  -target arm64-apple-macosx13.0 -framework PDFKit \
  Sources/Messages.swift Sources/BrowserAuthentication.swift Sources/DownloadError.swift Sources/Core.swift Sources/PDF.swift Sources/Media.swift Sources/Files.swift Sources/Douyin.swift Sources/Shared.swift Sources/AssetNaming.swift Sources/CLI.swift "$staging_dir/Version.swift" \
  -o "$staging_dir/folioak"
strip "$staging_dir/folioak"
codesign --force --options runtime --timestamp=none --sign - "$staging_dir/folioak"
codesign --verify --strict "$staging_dir/folioak"
xcrun lipo "$staging_dir/folioak" -verify_arch arm64
test "$("$staging_dir/folioak" --version)" = "$version"
"$staging_dir/folioak" --help > /dev/null
cp "$staging_dir/folioak" "$staged_app/Contents/MacOS/folioak"
ln -s folioak "$staged_app/Contents/MacOS/leafpick"
ln -s folioak "$staged_app/Contents/MacOS/arxiv-download"
# Sign nested code first, then seal the complete app bundle.
codesign --force --options runtime --timestamp=none --sign - "$staged_app"
codesign --verify --deep --strict "$staged_app"
xcrun lipo "$staged_app/Contents/MacOS/FolioakApp" -verify_arch arm64
for alias_name in leafpick arxiv-download; do
  alias_path="$staged_app/Contents/MacOS/$alias_name"
  test "$(readlink "$alias_path")" = folioak
  codesign --verify --strict "$alias_path"
  test "$("$alias_path" --version)" = "$version"
  "$alias_path" --help | /usr/bin/grep -q 'folioak'
  cmp "$staging_dir/folioak" "$alias_path"
done
rm -rf "$app_dir"
mv "$staged_app" "$app_dir"
mv -f "$staging_dir/folioak" "$project_dir/dist/folioak"
rm -rf "$project_dir/dist/media-tools"
cp -R build/media-tools "$project_dir/dist/"
cp "$project_dir/dist/folioak" "$project_dir/dist/arxiv-download"
cp "$project_dir/dist/folioak" "$project_dir/dist/leafpick"
print "已构建：$app_dir"
print "已构建：$project_dir/dist/folioak"
