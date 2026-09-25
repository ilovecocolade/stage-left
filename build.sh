#!/bin/bash
# Builds Stage Left.
#
#   ./build.sh            build, sign with your certificate, install into /Applications
#   ./build.sh --package  build the release download into build/release, install nothing
#
# The menu bar app needs only Command Line Tools. The Control Centre button is
# built too when a full Xcode is installed; see "The Control Centre button" in
# the README for why. A package always includes it.
set -euo pipefail

cd "$(dirname "$0")"
PACKAGE=false
case "${1:-}" in
    "") ;;
    --package) PACKAGE=true ;;
    *) echo "usage: $0 [--package]" >&2; exit 1 ;;
esac
APP="build/Stage Left.app"
APPEX="$APP/Contents/PlugIns/StageLeftControls.appex"
BUNDLE_ID="${STAGELEFT_BUNDLE_ID:-io.github.ilovecocolade.stageleft}"
VERSION="1.1"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# --- Signing identity ---------------------------------------------------------
# Sign with a real identity when one is available. An ad-hoc signature changes
# with every build, so macOS treats each build as a different app and silently
# voids the Accessibility permission; a real identity keeps the grant.
#
# A package is always signed ad-hoc. A development certificate names its owner,
# and the signature would carry that name to everyone who downloads the app.
IDENTITY="${STAGELEFT_IDENTITY:-}"
if $PACKAGE; then
    IDENTITY="-"
elif [ -z "$IDENTITY" ]; then
    IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | awk '/Apple Development|Developer ID Application/ { print $2; exit }')
fi
if [ -z "$IDENTITY" ]; then
    IDENTITY="-"
    echo "WARNING: no signing identity found, so ad-hoc signing. Accessibility"
    echo "         permission will need granting again after every build."
fi

# --- The menu bar app ---------------------------------------------------------
# Release by default. A debug build compiles in the diagnostic hooks described
# in the README, which anything able to launch the app can drive — build one
# only to investigate a problem, never to use day to day.
CONFIGURATION="${STAGELEFT_CONFIGURATION:-release}"
case "$CONFIGURATION" in
    release|debug) ;;
    *) echo "STAGELEFT_CONFIGURATION must be release or debug" >&2; exit 1 ;;
esac
if $PACKAGE && [ "$CONFIGURATION" != release ]; then
    echo "A package must be a release build" >&2; exit 1
fi
swift build -c "$CONFIGURATION"
BIN="$(swift build -c "$CONFIGURATION" --show-bin-path)/StageLeft"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/StageLeft"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>StageLeft</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Stage Left</string>
    <key>CFBundleDisplayName</key><string>Stage Left</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>Stage Manager, per screen.</string>
</dict>
</plist>
PLIST

# --- The Control Centre button ------------------------------------------------
# Needs appintentsmetadataprocessor, which ships with Xcode but not with Command
# Line Tools. Control Centre buttons arrived in macOS 26.
CONTROL_MIN_OS="26.0"
XCODE=""
for candidate in "${DEVELOPER_DIR:-}" \
                 /Applications/Xcode.app/Contents/Developer \
                 /Applications/Xcode-beta.app/Contents/Developer; do
    [ -n "$candidate" ] \
        && [ -x "$candidate/Toolchains/XcodeDefault.xctoolchain/usr/bin/appintentsmetadataprocessor" ] \
        && XCODE="$candidate" && break
done

if [ -n "$XCODE" ]; then
    export DEVELOPER_DIR="$XCODE"
    TOOLCHAIN="$XCODE/Toolchains/XcodeDefault.xctoolchain"
    SDK=$(xcrun --sdk macosx --show-sdk-path)
    SDK_VERSION=$(xcrun --sdk macosx --show-sdk-version)
    XCODE_BUILD=$(xcodebuild -version 2>/dev/null | sed -n 's/^Build version //p')
    TRIPLE="arm64-apple-macos$CONTROL_MIN_OS"
    WORK="build/control-build"

    rm -rf "$WORK"; mkdir -p "$WORK" "$APPEX/Contents/MacOS" "$APPEX/Contents/Resources"

    # The protocols whose conformances the metadata processor reads. Xcode
    # generates this list per target.
    cat > "$WORK/protocols.json" <<'PROTOCOLS'
["AppEntity","AppEnum","AppIntent","AppShortcutsProvider","DynamicOptionsProvider",
 "EntityIdentifierConvertible","EntityPropertyQuery","EntityQuery","EntityStringQuery",
 "IndexedEntity","PersistentlyIdentifiable","TransientAppEntity","UnionValue"]
PROTOCOLS

    # -wmo: without it no .swiftconstvalues file is written, and the metadata
    #   processor has nothing to read.
    # -e _NSExtensionMain: what Xcode sets for every app extension. Without it
    #   the Swift @main entry point runs instead of the extension runtime, and
    #   ExtensionKit traps the moment launchd starts the extension.
    xcrun swiftc -target "$TRIPLE" -sdk "$SDK" -parse-as-library -wmo -O \
        -module-name StageLeftControls \
        -Xlinker -e -Xlinker _NSExtensionMain \
        -emit-const-values-path "$WORK/StageLeftControls.swiftconstvalues" \
        -Xfrontend -const-gather-protocols-file -Xfrontend "$WORK/protocols.json" \
        -o "$APPEX/Contents/MacOS/StageLeftControls" \
        Extension/StageLeftControls.swift Sources/StageLeft/SharedState.swift

    printf '%s\n%s\n' "$PWD/Extension/StageLeftControls.swift" \
                       "$PWD/Sources/StageLeft/SharedState.swift" > "$WORK/sources.txt"
    echo "$PWD/$WORK/StageLeftControls.swiftconstvalues" > "$WORK/constvals.txt"

    # The Control Centre gallery finds the control's intent through this
    # metadata, not the binary: without it the control never appears.
    "$TOOLCHAIN/usr/bin/appintentsmetadataprocessor" \
        --output "$APPEX/Contents/Resources" \
        --toolchain-dir "$TOOLCHAIN" \
        --module-name StageLeftControls \
        --sdk-root "$SDK" \
        --xcode-version "$XCODE_BUILD" \
        --platform-family macOS \
        --deployment-target "$CONTROL_MIN_OS" \
        --target-triple "$TRIPLE" \
        --source-file-list "$WORK/sources.txt" \
        --swift-const-vals-list "$WORK/constvals.txt" \
        --force --quiet-warnings > /dev/null

    cat > "$APPEX/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>StageLeftControls</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID.Controls</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>StageLeftControls</string>
    <key>CFBundlePackageType</key><string>XPC!</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>$CONTROL_MIN_OS</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string>
    </dict>
</dict>
</plist>
PLIST
    rm -rf "$WORK"
    echo "Built Control Centre extension (SDK $SDK_VERSION, Xcode $XCODE_BUILD)"
elif $PACKAGE; then
    echo "A package needs Xcode, to build the Control Centre button" >&2; exit 1
else
    echo "Skipping Control Centre extension (needs Xcode — see README)"
fi

# --- Sign ---------------------------------------------------------------------
# A package leaves out debug information, which records where it was built:
# the builder's home folder, and so their user name.
if $PACKAGE; then
    strip -S -x "$APP/Contents/MacOS/StageLeft" "$APPEX/Contents/MacOS/StageLeftControls"
fi

# Nested code is signed inside out, so the app's seal covers the extension.
#
# --options runtime turns on the Hardened Runtime. Stage Left holds the user's
# Accessibility permission; without the Hardened Runtime, anything that can
# launch it can inject a library through DYLD_INSERT_LIBRARIES and inherit that
# permission. Never add the allow-dyld-environment-variables or
# disable-library-validation entitlements, which would reopen exactly that.
#
# The app needs no entitlements. The extension needs only the sandbox.
[ -d "$APPEX" ] && codesign --force --sign "$IDENTITY" --timestamp=none --options runtime \
    --entitlements Extension/Controls.entitlements "$APPEX"
codesign --force --sign "$IDENTITY" --timestamp=none --options runtime "$APP"
codesign --verify --strict --deep "$APP"

# --- Package ------------------------------------------------------------------
# A zip with no extended attributes, resource forks or ACLs, which could carry
# details of this Mac, and a checksum to publish beside it.
if $PACKAGE; then
    for code in "$APPEX" "$APP"; do
        codesign -dv "$code" 2>&1 | grep '^Signature=adhoc$' > /dev/null \
            || { echo "Refusing to package: $code is not signed ad-hoc" >&2; exit 1; }
    done
    RELEASE="build/release"
    ZIP="Stage-Left-$VERSION.zip"
    rm -rf "$RELEASE"; mkdir -p "$RELEASE"
    ditto -c -k --norsrc --noextattr --noacl --keepParent "$APP" "$RELEASE/$ZIP"
    (cd "$RELEASE" && shasum -a 256 "$ZIP" > "$ZIP.sha256")
    "$LSREGISTER" -u "$PWD/$APP" 2>/dev/null || true
    rm -rf "$APP"
    echo "Packaged $RELEASE/$ZIP"
    cat "$RELEASE/$ZIP.sha256"
    exit 0
fi

# --- Install ------------------------------------------------------------------
# /Applications, not ~/Applications: the widget daemon only launches extensions
# from a system application directory. From a home folder the extension is
# listed but never started, so the Control Centre button never appears.
INSTALLED="/Applications/Stage Left.app"
if ! rm -rf "$INSTALLED" 2>/dev/null || ! cp -R "$APP" "$INSTALLED" 2>/dev/null; then
    INSTALLED="$HOME/Applications/Stage Left.app"
    mkdir -p "$HOME/Applications"
    rm -rf "$INSTALLED"
    cp -R "$APP" "$INSTALLED"
    echo "WARNING: /Applications is not writable, so installed to $INSTALLED."
    echo "         The Control Centre button will not appear from there."
fi
"$LSREGISTER" -f "$INSTALLED" 2>/dev/null || true

# Leave nothing launchable behind in build/. Spotlight indexes this folder, and
# opening Stage Left from there once started a second copy alongside the
# installed one.
"$LSREGISTER" -u "$PWD/$APP" 2>/dev/null || true
rm -rf "$APP"

echo "Installed $INSTALLED"
