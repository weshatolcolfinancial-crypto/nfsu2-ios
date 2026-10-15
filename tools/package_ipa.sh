#!/usr/bin/env bash
# Package the compiled iOS application bundle into an unsigned / ad-hoc signed .ipa
#
# Usage:
#   tools/package_ipa.sh [app_bundle_path] [output_ipa_path]
#
# Defaults:
#   app_bundle_path:  build-ios/Release-iphoneos/nfsu2_recomp.app
#   output_ipa_path:  build-ios/NFSU2-iOS-unsigned.ipa

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-$HERE/build-ios/Release-iphoneos/nfsu2_recomp.app}"
IPA_PATH="${2:-$HERE/build-ios/NFSU2-iOS-unsigned.ipa}"
ENTITLEMENTS="$HERE/ios/nfsu2_recomp.entitlements"
DEPS="${DEPS:-$HOME/nfsu2/deps/device}"

if [ ! -d "$APP_PATH" ]; then
    echo "Error: App bundle not found at '$APP_PATH'" >&2
    echo "Build the project with xcodebuild first." >&2
    exit 1
fi

echo "==> Packaging iOS IPA from: $APP_PATH"

STAGE_DIR="$(mktemp -d -t nfsu2_ipa_XXXXXX)"
PAYLOAD_DIR="$STAGE_DIR/Payload"
mkdir -p "$PAYLOAD_DIR"

# Copy .app bundle into Payload/
DEST_APP="$PAYLOAD_DIR/NFSU2.app"
cp -R "$APP_PATH" "$DEST_APP"

# Embed FFmpeg frameworks if available in deps
if [ -d "$DEPS/Frameworks/avcodec.framework" ] && [ ! -d "$DEST_APP/Frameworks/avcodec.framework" ]; then
    echo "==> Embedding FFmpeg frameworks..."
    mkdir -p "$DEST_APP/Frameworks"
    cp -R "$DEPS/Frameworks/avcodec.framework" "$DEST_APP/Frameworks/"
    cp -R "$DEPS/Frameworks/avutil.framework" "$DEST_APP/Frameworks/"
fi

# Embed App Icon
if [ -f "$HERE/assets/icon.jpg" ]; then
    echo "==> Embedding App Icons..."
    cp "$HERE/assets/icon.jpg" "$DEST_APP/AppIcon.jpg"
    if command -v sips &>/dev/null; then
        sips -s format png "$HERE/assets/icon.jpg" --out "$DEST_APP/AppIcon.png" &>/dev/null || true
        sips -z 120 120 "$DEST_APP/AppIcon.png" --out "$DEST_APP/AppIcon60x60@2x.png" &>/dev/null || true
        sips -z 180 180 "$DEST_APP/AppIcon.png" --out "$DEST_APP/AppIcon60x60@3x.png" &>/dev/null || true
        sips -z 152 152 "$DEST_APP/AppIcon.png" --out "$DEST_APP/AppIcon76x76@2x~ipad.png" &>/dev/null || true
        sips -z 167 167 "$DEST_APP/AppIcon.png" --out "$DEST_APP/AppIcon83.5x83.5@2x~ipad.png" &>/dev/null || true
    fi
fi

# Ad-hoc codesign if running on macOS with codesign tool
if command -v codesign &>/dev/null; then
    echo "==> Signing embedded frameworks and app bundle (ad-hoc)..."
    if [ -d "$DEST_APP/Frameworks" ]; then
        for fw in "$DEST_APP/Frameworks/"*.framework; do
            if [ -d "$fw" ]; then
                codesign --force --sign - "$fw" 2>/dev/null || true
            fi
        done
    fi
    if [ -f "$ENTITLEMENTS" ]; then
        codesign --force --deep --sign - --entitlements "$ENTITLEMENTS" "$DEST_APP" 2>/dev/null || \
        codesign --force --deep --sign - "$DEST_APP" 2>/dev/null || true
    else
        codesign --force --deep --sign - "$DEST_APP" 2>/dev/null || true
    fi
fi

# Create destination directory
mkdir -p "$(dirname "$IPA_PATH")"
rm -f "$IPA_PATH"

echo "==> Compressing into $IPA_PATH..."
(cd "$STAGE_DIR" && zip -q -r -9 "$IPA_PATH" Payload)

rm -rf "$STAGE_DIR"

if [ -f "$IPA_PATH" ]; then
    SIZE=$(ls -lh "$IPA_PATH" | awk '{print $5}')
    echo "==> IPA package created successfully: $IPA_PATH ($SIZE)"
    if command -v shasum &>/dev/null; then
        shasum -a 256 "$IPA_PATH"
    elif command -v sha256sum &>/dev/null; then
        sha256sum "$IPA_PATH"
    fi
else
    echo "Error: Failed to create $IPA_PATH" >&2
    exit 1
fi
