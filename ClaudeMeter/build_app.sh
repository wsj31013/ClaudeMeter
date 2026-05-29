#!/bin/bash
set -e

cd "$(dirname "$0")"

VERSION="${1:-1.0.0}"
APP_DIR="ClaudeMeter.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "Building ClaudeMeter $VERSION..."

# Build arm64 (Apple Silicon)
echo "  [1/2] arm64..."
swift build -c release --arch arm64

# Try x86_64 (Intel) for universal binary
echo "  [2/2] x86_64..."
if swift build -c release --arch x86_64 2>/dev/null; then
    echo "  Creating universal binary..."
    lipo -create \
        .build/arm64-apple-macosx/release/ClaudeMeter \
        .build/x86_64-apple-macosx/release/ClaudeMeter \
        -output /tmp/ClaudeMeter_binary
    BINARY="/tmp/ClaudeMeter_binary"
    ARCH_LABEL="universal"
else
    echo "  Note: x86_64 build unavailable — arm64 only"
    BINARY=".build/arm64-apple-macosx/release/ClaudeMeter"
    ARCH_LABEL="arm64"
fi

# Assemble .app bundle
rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES"

cp "$BINARY" "$MACOS/ClaudeMeter"
cp "Sources/ClaudeMeter/Info.plist" "$CONTENTS/Info.plist"

# Embed version into Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$CONTENTS/Info.plist"

codesign --force --deep --sign - "$APP_DIR"

# Create distributable zip
ZIP_NAME="ClaudeMeter-${VERSION}-${ARCH_LABEL}.zip"
rm -f "$ZIP_NAME"
zip -r --quiet "$ZIP_NAME" "$APP_DIR"

echo ""
echo "✅  App:  $(pwd)/$APP_DIR"
echo "📦  Zip:  $(pwd)/$ZIP_NAME"
echo ""
echo "GitHub Release 업로드: $ZIP_NAME"
echo "로컬 실행: open $APP_DIR"
echo "설치:      cp -r $APP_DIR /Applications/"
