#!/bin/bash
# RAMBar.app 빌드 → ./build.sh 실행 후 RAMBar.app을 /Applications로 옮기면 끝
set -euo pipefail
cd "$(dirname "$0")"

APP="RAMBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -swift-version 5 -target arm64-apple-macos13.0 \
    main.swift -o "$APP/Contents/MacOS/RAMBar"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"   # 로컬 실행용 ad-hoc 서명

echo "✅ $APP 빌드 완료 — open $APP 으로 실행"
