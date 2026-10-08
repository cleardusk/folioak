#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h}"
cd "$project_dir"
mkdir -p build
xcrun swiftc -parse-as-library -swift-version 5 -D TESTING \
  -framework AppKit -framework SwiftUI -framework PDFKit \
  Sources/Core.swift Sources/Theme.swift Sources/App.swift Tests/TestMain.swift Tests/TransportTests.swift \
  -o build/CoreTests
./build/CoreTests "$@"
