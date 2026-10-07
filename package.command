#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h}"
cd "$project_dir"
if (( $# != 0 )); then
  print -u2 '用法：./package.command'
  exit 1
fi
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
if [[ ! "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  print -u2 'Info.plist 版本号必须为 x.y.z。'
  exit 1
fi
if [[ -n "${RELEASE_TAG:-}" && "$RELEASE_TAG" != "v$version" ]]; then
  print -u2 "Tag 与应用版本不一致：期望 v$version。"
  exit 1
fi
./build.command
staging_dir=$(mktemp -d "$project_dir/build/package.XXXXXX")
trap 'rm -rf "$staging_dir"' EXIT
app_dir="$project_dir/dist/arXiv下载器.app"
asset_name="arxiv-downloader-v$version-macos-arm64"
ditto -c -k --norsrc --noextattr --keepParent "$app_dir" "$staging_dir/$asset_name.zip"
ditto -x -k "$staging_dir/$asset_name.zip" "$staging_dir/unpacked"
codesign --verify --deep --strict "$staging_dir/unpacked/arXiv下载器.app"
xcrun lipo "$staging_dir/unpacked/arXiv下载器.app/Contents/MacOS/ArxivDownloader" -verify_arch arm64
mkdir -p "$staging_dir/dmg"
ditto --norsrc --noextattr "$app_dir" "$staging_dir/dmg/arXiv下载器.app"
ln -s /Applications "$staging_dir/dmg/Applications"
hdiutil create -volname 'arXiv下载器' -srcfolder "$staging_dir/dmg" -format UDZO "$staging_dir/$asset_name.dmg"
hdiutil verify "$staging_dir/$asset_name.dmg"
mv -f "$staging_dir/$asset_name.zip" "$project_dir/dist/$asset_name.zip"
mv -f "$staging_dir/$asset_name.dmg" "$project_dir/dist/$asset_name.dmg"
cd "$project_dir/dist"
shasum -a 256 "$asset_name.zip" "$asset_name.dmg" > "$staging_dir/SHA256SUMS.txt"
mv -f "$staging_dir/SHA256SUMS.txt" SHA256SUMS.txt
print "已打包：$project_dir/dist/$asset_name.zip"
print "已打包：$project_dir/dist/$asset_name.dmg"
