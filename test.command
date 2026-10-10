#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h}"
cd "$project_dir"
mkdir -p build
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]
print -r -- "enum BuildVersion { static let current = \"$version\" }" > build/TestVersion.swift
xcrun swiftc -parse-as-library -swift-version 5 -O -D CLI_TESTING -framework PDFKit \
  Sources/Core.swift Sources/PDF.swift Sources/Shared.swift Sources/CLI.swift build/TestVersion.swift -o build/arxiv-download-test
xcrun swiftc -parse-as-library -swift-version 5 -framework PDFKit \
  Sources/Core.swift Sources/PDF.swift Sources/Shared.swift Tests/CoordinationProbe.swift -o build/CoordinationProbe
xcrun swiftc -parse-as-library -swift-version 5 -D TESTING \
  -framework AppKit -framework SwiftUI -framework PDFKit \
  Sources/Core.swift Sources/PDF.swift Sources/Shared.swift Sources/CLI.swift Sources/Theme.swift Sources/Workspace.swift Sources/WorkspaceView.swift Sources/Interaction.swift Sources/SidebarMotion.swift Sources/App.swift Tests/TestMain.swift Tests/TransportTests.swift Tests/SharedTests.swift Tests/FeatureTests.swift Tests/PDFTests.swift Tests/WorkspaceTests.swift Tests/InteractionRenderingTests.swift \
  -o build/CoreTests
./build/CoreTests "$@"
