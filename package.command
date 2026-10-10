#!/bin/zsh
set -euo pipefail
TRAPZERR() {
  local failure=$?
  print -u2 -- "打包检查失败（退出码 $failure）：${funcfiletrace[1]}"
  return "$failure"
}
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
app_dir="$project_dir/dist/Leafpick.app"
asset_name="Leafpick-v$version-macos-arm64"
cli_asset="leafpick-cli-v$version-macos-arm64"
mkdir -p "$staging_dir/cli/leafpick"
cp "$project_dir/dist/arxiv-download" "$staging_dir/cli/leafpick/leafpick"
cp -R build/media-tools "$staging_dir/cli/leafpick/media-tools"
cp CLI-README.md "$staging_dir/cli/leafpick/README.md"
ditto -c -k --norsrc --noextattr --keepParent "$staging_dir/cli/leafpick" "$staging_dir/$cli_asset.zip"
ditto -x -k "$staging_dir/$cli_asset.zip" "$staging_dir/cli-unpacked"
codesign --verify --strict "$staging_dir/cli-unpacked/leafpick/leafpick"
xcrun lipo "$staging_dir/cli-unpacked/leafpick/leafpick" -verify_arch arm64
test "$("$staging_dir/cli-unpacked/leafpick/leafpick" --version)" = "$version"
ditto -c -k --norsrc --noextattr --keepParent "$app_dir" "$staging_dir/$asset_name.zip"
ditto -x -k "$staging_dir/$asset_name.zip" "$staging_dir/unpacked"
codesign --verify --deep --strict "$staging_dir/unpacked/Leafpick.app"
for media_dir in "$staging_dir/unpacked/Leafpick.app/Contents/Resources/media-tools" "$staging_dir/cli-unpacked/leafpick/media-tools"; do
  for binary in "$media_dir/ffmpeg" "$media_dir/ffprobe" "$media_dir/"*.dylib; do
    codesign --verify --strict "$binary"
  done
  "$media_dir/ffmpeg" -version > /dev/null
  "$media_dir/ffprobe" -v error -show_entries stream=codec_name -of json Tests/Fixtures/Media/tone.m4a > /dev/null
  codesign --verify --strict "$media_dir/qjs"
  "$media_dir/yt-dlp" --ignore-config --no-plugin-dirs --plugin-dirs "$project_dir/Tests/Fixtures/EJS" \
    --no-remote-components --no-update --no-cache-dir --no-js-runtimes --js-runtimes "quickjs:$media_dir/qjs" \
    --skip-download --print title leafpick-ejs:fixture | /usr/bin/grep -qx 'EJS provider passed'
done
xcrun lipo "$staging_dir/unpacked/Leafpick.app/Contents/MacOS/LeafpickApp" -verify_arch arm64
bundled_cli="$staging_dir/unpacked/Leafpick.app/Contents/MacOS/arxiv-download"
codesign --verify --strict "$bundled_cli"
xcrun lipo "$bundled_cli" -verify_arch arm64
test "$("$bundled_cli" --version)" = "$version"
"$bundled_cli" --help > /dev/null
cmp "$bundled_cli" "$staging_dir/cli-unpacked/leafpick/leafpick"
invalid_status=0
"$bundled_cli" not-an-arxiv-link --json > "$staging_dir/invalid.json" 2> "$staging_dir/invalid.stderr" || invalid_status=$?
if [[ "$invalid_status" != 1 ]]; then
  cat "$staging_dir/invalid.stderr" >&2
  print -u2 -- "内置 CLI 错误输入检查失败：退出码 $invalid_status，期望 1。"
  exit 1
fi
xcrun swift -e 'import Foundation
let report = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
let rows = report["results"] as! [[String: Any]]
precondition(report["schema"] as? Int == 1 && rows.count == 1 && rows[0]["status"] as? String == "failed")' "$staging_dir/invalid.json"
mkdir -p "$staging_dir/dmg"
ditto --norsrc --noextattr "$app_dir" "$staging_dir/dmg/Leafpick.app"
ln -s /Applications "$staging_dir/dmg/Applications"
# LZMA disk images are supported since macOS 10.15; Leafpick requires macOS 13.
hdiutil create -volname 'Leafpick 拾取' -srcfolder "$staging_dir/dmg" -format ULMO "$staging_dir/$asset_name.dmg"
hdiutil verify "$staging_dir/$asset_name.dmg"
mv -f "$staging_dir/$asset_name.zip" "$project_dir/dist/$asset_name.zip"
mv -f "$staging_dir/$asset_name.dmg" "$project_dir/dist/$asset_name.dmg"
mv -f "$staging_dir/$cli_asset.zip" "$project_dir/dist/$cli_asset.zip"
cd "$project_dir/dist"
shasum -a 256 "$asset_name.zip" "$asset_name.dmg" "$cli_asset.zip" > "$staging_dir/SHA256SUMS.txt"
mv -f "$staging_dir/SHA256SUMS.txt" SHA256SUMS.txt
print "已打包：$project_dir/dist/$asset_name.zip"
print "已打包：$project_dir/dist/$asset_name.dmg"
print "已打包：$project_dir/dist/$cli_asset.zip"
