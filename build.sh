#!/bin/bash
# RAMBar 빌드
#   ./build.sh       → RAMBar.app  (Apple Silicon + Intel 유니버설)
#   ./build.sh dmg   → RAMBar.app + RAMBar.dmg (배포용, Applications 바로가기 포함)
set -euo pipefail
cd "$(dirname "$0")"

APP="RAMBar.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)

rm -rf "$APP" .build
mkdir -p "$APP/Contents/MacOS" .build

for arch in arm64 x86_64; do
    swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" \
        main.swift -o ".build/RAMBar-$arch"
done
lipo -create .build/RAMBar-arm64 .build/RAMBar-x86_64 -output "$APP/Contents/MacOS/RAMBar"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"   # ad-hoc 서명 (Apple 공증 전)

echo "✅ $APP v$VERSION 빌드 완료 ($(lipo -archs "$APP/Contents/MacOS/RAMBar"))"

if [[ "${1:-}" == "dmg" ]]; then
    STAGE=".build/dmg"
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    rm -f RAMBar.dmg
    hdiutil create -volname "RAMBar $VERSION" -srcfolder "$STAGE" -ov -format UDZO RAMBar.dmg >/dev/null
    echo "✅ RAMBar.dmg 생성 완료 ($(du -h RAMBar.dmg | cut -f1))"
fi
