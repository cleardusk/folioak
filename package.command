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
app_dir="$project_dir/dist/arXiv下载器.app"
asset_name="arxiv-downloader-v$version-macos-arm64"
cli_asset="arxiv-download-cli-v$version-macos-arm64"
mkdir -p "$staging_dir/cli/arxiv-download"
cp "$project_dir/dist/arxiv-download" "$staging_dir/cli/arxiv-download/arxiv-download"
cp CLI-README.md "$staging_dir/cli/arxiv-download/README.md"
ditto -c -k --norsrc --noextattr --keepParent "$staging_dir/cli/arxiv-download" "$staging_dir/$cli_asset.zip"
ditto -x -k "$staging_dir/$cli_asset.zip" "$staging_dir/cli-unpacked"
codesign --verify --strict "$staging_dir/cli-unpacked/arxiv-download/arxiv-download"
xcrun lipo "$staging_dir/cli-unpacked/arxiv-download/arxiv-download" -verify_arch arm64
test "$("$staging_dir/cli-unpacked/arxiv-download/arxiv-download" --version)" = "$version"
ditto -c -k --norsrc --noextattr --keepParent "$app_dir" "$staging_dir/$asset_name.zip"
ditto -x -k "$staging_dir/$asset_name.zip" "$staging_dir/unpacked"
codesign --verify --deep --strict "$staging_dir/unpacked/arXiv下载器.app"
xcrun lipo "$staging_dir/unpacked/arXiv下载器.app/Contents/MacOS/ArxivDownloader" -verify_arch arm64
bundled_cli="$staging_dir/unpacked/arXiv下载器.app/Contents/MacOS/arxiv-download"
codesign --verify --strict "$bundled_cli"
xcrun lipo "$bundled_cli" -verify_arch arm64
test "$("$bundled_cli" --version)" = "$version"
"$bundled_cli" --help > /dev/null
cmp "$bundled_cli" "$staging_dir/cli-unpacked/arxiv-download/arxiv-download"
if "$bundled_cli" not-an-arxiv-link --json > "$staging_dir/invalid.json" 2> "$staging_dir/invalid.stderr"; then
  print -u2 '内置 CLI 错误输入检查失败。'
  exit 1
else
  test "$?" = 1
fi
xcrun swift -e 'import Foundation
let report = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
let rows = report["results"] as! [[String: Any]]
precondition(report["schema"] as? Int == 1 && rows.count == 1 && rows[0]["status"] as? String == "failed")' "$staging_dir/invalid.json"
mkdir -p "$staging_dir/dmg"
ditto --norsrc --noextattr "$app_dir" "$staging_dir/dmg/arXiv下载器.app"
ln -s /Applications "$staging_dir/dmg/Applications"
hdiutil create -volname 'arXiv下载器' -srcfolder "$staging_dir/dmg" -format UDZO "$staging_dir/$asset_name.dmg"
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
