#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h}"
cd "$project_dir"
mkdir -p build/en.lproj
cp Resources/en.lproj/Localizable.strings build/en.lproj/
python3 Tools/prepare-media.py
python3 Tests/MediaToolsTests.py
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]
print -r -- "enum BuildVersion { static let current = \"$version\" }" > build/TestVersion.swift
xcrun swiftc -parse-as-library -swift-version 5 -O -D CLI_TESTING -framework PDFKit \
  Sources/Messages.swift Sources/BrowserAuthentication.swift Sources/DownloadError.swift Sources/Core.swift Sources/PDF.swift Sources/Media.swift Sources/Douyin.swift Sources/Shared.swift Sources/CLI.swift build/TestVersion.swift -o build/folioak-test
xcrun swiftc -parse-as-library -swift-version 5 -framework PDFKit \
  Sources/Messages.swift Sources/BrowserAuthentication.swift Sources/DownloadError.swift Sources/Core.swift Sources/PDF.swift Sources/Media.swift Sources/Douyin.swift Sources/Shared.swift Tests/CoordinationProbe.swift -o build/CoordinationProbe
xcrun swiftc -parse-as-library -swift-version 5 -D TESTING \
  -framework AppKit -framework SwiftUI -framework PDFKit -framework QuickLookThumbnailing \
  Sources/Messages.swift Sources/BrowserAuthentication.swift Sources/DownloadError.swift Sources/Core.swift Sources/PDF.swift Sources/Media.swift Sources/Douyin.swift Sources/Shared.swift Sources/CLI.swift Sources/Localization.swift Sources/Theme.swift Sources/Workspace.swift Sources/WorkspacePersistence.swift Sources/Library.swift Sources/Shortcuts.swift Sources/WorkspaceView.swift Sources/Interaction.swift Sources/FileInformation.swift Sources/MediaThumbnail.swift Sources/SidebarMotion.swift Sources/BrowserAuthenticationSettings.swift Sources/Updates.swift Sources/App.swift Tests/TestMain.swift Tests/UpdateTests.swift Tests/TransportTests.swift Tests/SharedTests.swift Tests/FeatureTests.swift Tests/LibraryTests.swift Tests/PDFTests.swift Tests/WorkspaceTests.swift Tests/InteractionRenderingTests.swift \
  Tests/MediaTests.swift Tests/DouyinTests.swift Tests/BrowserAuthenticationTests.swift Tests/MessageTests.swift Tests/FileInformationTests.swift Tests/LocalizationTests.swift Tests/PersistenceTests.swift -o build/CoreTests
./build/CoreTests "$@"
