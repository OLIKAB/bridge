#!/bin/bash
# Builds Bridge as a universal (Apple Silicon + Intel) app into ./build.
#   ./build.sh            build only
#   ./build.sh --install  also copy to /Applications and relaunch
#   ./build.sh --dist     also create a .zip and a .dmg for sharing in dist/
#   ./build.sh --release  --dist, then publish them as the GitHub release Bridge updates itself from
#                         (raise VERSION below first; UPDATE_REPO picks the repository, NOTARY_PROFILE notarizes)
set -euo pipefail
cd "$(dirname "$0")"

VERSION="1.0.0"

# The GitHub repository whose releases Bridge checks for updates (written into its Info.plist).
UPDATE_REPO="${UPDATE_REPO:-OLIKAB/bridge}"

# Where Bridge sends its one anonymous ping a day (UsagePing.swift; the endpoint is in telemetry/).
# USAGE_PING_URL= (empty) sends nothing and hides the switch in Settings, e.g. for a fork's builds.
USAGE_PING_URL="${USAGE_PING_URL-https://bridge-usage.olikab.workers.dev/ping}"

MODE=""
RELEASE=0
for arg in "$@"; do
    case "$arg" in
        --install | --dist) MODE="$arg" ;;
        --release) MODE="--dist"; RELEASE=1 ;;
        bridge) ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

BUILD_ARGS=(-c release --arch arm64 --arch x86_64)
swift build "${BUILD_ARGS[@]}" --product Bridge
# Ask instead of hard-coding: the output folder differs between Swift toolchains.
PRODUCTS=$(swift build "${BUILD_ARGS[@]}" --show-bin-path)

APP=build/Bridge.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PRODUCTS/Bridge" "$APP/Contents/MacOS/"
cp Resources/BridgeIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp LICENSE "$APP/Contents/Resources/LICENSE"
cp -R Resources/Logos "$APP/Contents/Resources/"
rm -f "$APP/Contents/Resources/Logos/README.md"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Bridge</string>
    <key>CFBundleDisplayName</key><string>Bridge</string>
    <key>CFBundleIdentifier</key><string>com.olikab.bridge</string>
    <key>CFBundleExecutable</key><string>Bridge</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>LSUIElement</key><true/>
    <key>UpdateRepository</key><string>${UPDATE_REPO}</string>
    <key>UsagePingURL</key><string>${USAGE_PING_URL}</string>
    <key>NSAppleEventsUsageDescription</key><string>Bridge opens tabs in your terminal and runs commands there.</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 OLIKAB. MIT License.</string>
</dict>
</plist>
PLIST

# Access to ~/Documents and the like is tied to the signature, and everything Bridge starts (dev servers,
# git, a coding agent's daemon) runs with Bridge's access. An ad-hoc signature changes with every build,
# and then those fail with EPERM until access is granted again, so a real certificate is used when there
# is one. For --dist with NOTARY_PROFILE set (a profile saved with `xcrun notarytool store-credentials`),
# it has to be a Developer ID one, signed with the hardened runtime and a timestamp, which notarization
# requires. Without notarization, Gatekeeper on other Macs blocks the app until it's allowed in
# System Settings › Privacy & Security. Updates Bridge installs itself are trusted only when signed by the
# same team as the copy that's running (AppUpdate.swift), so release builds have to keep one certificate.
if [[ "$MODE" == "--dist" && -n "${NOTARY_PROFILE:-}" ]]; then
    IDENTITY=$(security find-identity -v -p codesigning | grep -m1 -oE '"Developer ID Application: [^"]+"' | tr -d '"' || true)
    if [[ -z "$IDENTITY" ]]; then
        echo "NOTARY_PROFILE is set, but there's no Developer ID Application certificate to sign with." >&2
        exit 1
    fi
    # Apple Events go out through osascript (Rex), a process of its own, but the entitlement keeps the
    # hardened runtime from refusing them if Bridge ever sends one itself.
    ENTITLEMENTS=$(mktemp)
    cat > "$ENTITLEMENTS" <<ENTITLEMENTS
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.automation.apple-events</key><true/>
</dict>
</plist>
ENTITLEMENTS
    codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
    rm -f "$ENTITLEMENTS"
else
    IDENTITY=$(security find-identity -v -p codesigning | grep -m1 -oE '"(Apple Development|Developer ID Application): [^"]+"' | tr -d '"' || true)
    codesign --force --sign "${IDENTITY:--}" "$APP"
fi
echo "Built: $APP ($(lipo -archs "$APP/Contents/MacOS/Bridge"), $(du -sh "$APP" | cut -f1))"

if [[ "$MODE" == "--install" ]]; then
    pkill -x Bridge || true
    # Bridge quits the usual way on SIGTERM and first stops its dev servers; `open` while the old copy
    # still runs would only bring that one forward. Wait up to 5 s for it to go.
    for _ in $(seq 50); do pgrep -x Bridge >/dev/null || break; sleep 0.1; done
    rm -rf /Applications/Bridge.app
    cp -R "$APP" /Applications/
    open /Applications/Bridge.app
    echo "Installed /Applications/Bridge.app"
fi

if [[ "$MODE" == "--dist" ]]; then
    mkdir -p dist
    ZIP="dist/Bridge-${VERSION}.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    # Sent to Apple's notary service through the zip, then zipped again with the ticket stapled to the app,
    # so it opens on other Macs without a Gatekeeper warning, offline too.
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$APP"
        rm -f "$ZIP"
        ditto -c -k --keepParent "$APP" "$ZIP"
    else
        echo "Not notarized (set NOTARY_PROFILE to a notarytool keychain profile to notarize)."
    fi
    echo "Created: $ZIP ($(du -h "$ZIP" | cut -f1))"

    # A designed installer window (background in the app's style, the app icon on the disk) through
    # dmgbuild, run with uvx so nothing is installed for good. Without uvx, a plain image: the app next to a
    # link to /Applications, made with hdiutil, which ships with macOS.
    DMG="dist/Bridge-${VERSION}.dmg"
    rm -f "$DMG"
    if command -v uvx >/dev/null; then
        uvx --quiet --from dmgbuild==1.6.7 dmgbuild -s scripts/bridge-dmg-settings.py \
            -D app="$APP" -D background=Resources/BridgeDMGBackground.tiff -D icon=Resources/BridgeIcon.icns \
            "Bridge" "$DMG"
    else
        STAGING=$(mktemp -d)
        cp -R "$APP" "$STAGING/"
        ln -s /Applications "$STAGING/Applications"
        hdiutil create -quiet -volname "Bridge" -srcfolder "$STAGING" -fs HFS+ -format UDZO "$DMG"
        rm -rf "$STAGING"
    fi
    # The disk image is what's downloaded, so it's signed, notarized and stapled too: Gatekeeper then
    # checks it before it's even opened, instead of only the app once it's been copied out.
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        codesign --force --sign "$IDENTITY" --timestamp "$DMG"
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG"
    fi
    echo "Created: $DMG ($(du -h "$DMG" | cut -f1))"

    # Bridge checks for releases tagged bridge-v<version> and updates itself from the zip (AppUpdate.swift).
    if [[ "$RELEASE" == 1 ]]; then
        if gh release view "bridge-v${VERSION}" --repo "$UPDATE_REPO" >/dev/null 2>&1; then
            echo "bridge-v${VERSION} is already released on $UPDATE_REPO: raise VERSION in build.sh first." >&2
            exit 1
        fi
        gh release create "bridge-v${VERSION}" "$ZIP" "$DMG" \
            --repo "$UPDATE_REPO" --title "Bridge ${VERSION}" --generate-notes
        echo "Released Bridge ${VERSION} on $UPDATE_REPO; running copies offer the update within six hours, or at once from Settings."
    else
        echo "To publish: ./build.sh --release"
    fi
fi
