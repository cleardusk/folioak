#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h}"
cd "$project_dir"
mkdir -p build/en.lproj
cp Resources/en.lproj/Localizable.strings build/en.lproj/
cp Resources/FolioakGlyph.png build/
python3 Tools/prepare-media.py
details_only=0
for argument in "$@"; do [[ "$argument" == "--page-switch-only" || "$argument" == "--library-management-only" || "$argument" == "--ui-only" || "$argument" == "--stress-only" || "$argument" == "--trace-only" || "$argument" == "--logs-only" || "$argument" == "--preferences-only" || "$argument" == "--pdf-directory-only" || "$argument" == "--details-only" || "$argument" == "--library-polish-only" || "$argument" == "--library-details-only" ]] && details_only=1; done
if (( ! details_only )); then python3 Tests/MediaToolsTests.py; fi
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]
print -r -- "enum BuildVersion { static let current = \"$version\" }" > build/TestVersion.swift
if (( ! details_only )); then
xcrun swiftc -parse-as-library -swift-version 5 -O -D CLI_TESTING -framework PDFKit \
  Sources/Messages.swift Sources/BrowserAuthentication.swift Sources/DownloadError.swift Sources/Core.swift Sources/PDF.swift Sources/Media.swift Sources/Files.swift Sources/Douyin.swift Sources/Shared.swift Sources/AssetNaming.swift Sources/CLI.swift build/TestVersion.swift -o build/folioak-test
xcrun swiftc -parse-as-library -swift-version 5 -framework PDFKit \
  Sources/Messages.swift Sources/BrowserAuthentication.swift Sources/DownloadError.swift Sources/Core.swift Sources/PDF.swift Sources/Media.swift Sources/Files.swift Sources/Douyin.swift Sources/Shared.swift Sources/AssetNaming.swift Tests/CoordinationProbe.swift -o build/CoordinationProbe
fi
test_optimization=()
if [[ "${FOLIOAK_TEST_OPTIMIZE:-0}" == "1" ]]; then test_optimization=(-O); fi
# Type-check the test target once instead of repeating it for every source file.
xcrun swiftc -parse-as-library -swift-version 5 -D TESTING -whole-module-optimization "${test_optimization[@]}" \
  -framework AppKit -framework SwiftUI -framework PDFKit -framework QuickLookThumbnailing \
  Sources/Messages.swift Sources/BrowserAuthentication.swift Sources/DownloadError.swift Sources/Core.swift Sources/PDF.swift Sources/Media.swift Sources/Files.swift Sources/Douyin.swift Sources/Shared.swift Sources/AssetNaming.swift Sources/CLI.swift Sources/Localization.swift Sources/Theme.swift Sources/Workspace.swift Sources/WorkspacePersistence.swift Sources/Library.swift Sources/AssetRename.swift Sources/Shortcuts.swift Sources/LibraryPresentation.swift Sources/WorkspaceView.swift Sources/Interaction.swift Sources/FileInformation.swift Sources/MediaThumbnail.swift Sources/SidebarMotion.swift Sources/WorkspaceBrand.swift Sources/BrowserAuthenticationSettings.swift Sources/Updates.swift Sources/QuickDownload.swift Sources/AssetNamingSettings.swift Sources/InteractionTrace.swift Sources/InteractionTraceSettings.swift Sources/PreferencesPages.swift Sources/App.swift Tests/TestMain.swift Tests/UpdateTests.swift Tests/TransportTests.swift Tests/SharedTests.swift Tests/FeatureTests.swift Tests/LibraryTests.swift Tests/PDFTests.swift Tests/WorkspaceTests.swift Tests/InteractionRenderingTests.swift Tests/ThumbnailTests.swift Tests/LibraryManagementTests.swift Tests/LibrarySelectionTests.swift \
  Tests/MediaTests.swift Tests/DouyinTests.swift Tests/BrowserAuthenticationTests.swift Tests/MessageTests.swift Tests/FileInformationTests.swift Tests/LocalizationTests.swift Tests/PersistenceTests.swift Tests/QuickDownloadTests.swift Tests/StageOneTests.swift Tests/GenericFileTests.swift Tests/AssetNamingTests.swift Tests/LibraryGridTests.swift Tests/DownloadProgressTests.swift Tests/AssetRenameTests.swift Tests/LibraryPolishUITests.swift Tests/LibraryDetailsTests.swift Tests/WorkspacePreferencesTests.swift Tests/InteractionTraceTests.swift -o build/CoreTests
result_log=$(mktemp "${TMPDIR:-/tmp/}folioak-tests.XXXXXX")
trap 'rm -f "$result_log"' EXIT
./build/CoreTests "$@" | tee "$result_log"
# AppKit can terminate a command-line host with status 0 before async tests finish.
if ! /usr/bin/grep -Fxq 'PASS core test suite completed' "$result_log"; then
  print -u2 -- 'FAIL: core tests exited before completing the requested suite'
  exit 1
fi
