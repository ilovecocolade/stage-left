#!/bin/bash
# Builds Stage Left and installs it into /Applications.
#
# The menu bar app needs only Command Line Tools. The Control Centre button is
# built too when a full Xcode is installed; see "The Control Centre button" in
# the README for why.
set -euo pipefail

cd "$(dirname "$0")"
APP="build/Stage Left.app"
APPEX="$APP/Contents/PlugIns/StageLeftControls.appex"
BUNDLE_ID="${STAGELEFT_BUNDLE_ID:-io.github.ilovecocolade.stageleft}"
VERSION="1.0"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# --- Signing identity ---------------------------------------------------------
# Sign with a real identity when one is available. An ad-hoc signature changes
# with every build, so macOS treats each build as a different app and silently
# voids the Accessibility permission; a real identity keeps the grant.
IDENTITY="${STAGELEFT_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | awk '/Apple Development|Developer ID Application/ { print $2; exit }')
fi

# The app and its Control Centre extension share preferences through an app
# group, whose name must start with the signing team. Read the team from the
# certificate rather than writing it into the source.
TEAM_ID="${STAGELEFT_TEAM_ID:-}"
if [ -n "$TEAM_ID" ] && ! [[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
    echo "STAGELEFT_TEAM_ID must be a 10-character Apple team ID" >&2
    exit 1
fi
if [ -z "$TEAM_ID" ] && [ -n "$IDENTITY" ]; then
    TEAM_ID=$(security find-certificate -a -Z -p 2>/dev/null \
        | awk -v want="$IDENTITY" '/^SHA-1 hash:/ { keep = ($3 == want) } keep && !/hash:/ { print }' \
        | openssl x509 -noout -subject 2>/dev/null \
        | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p')
fi
if [ -n "$TEAM_ID" ]; then
    APP_GROUP="$TEAM_ID.$BUNDLE_ID"
else
    APP_GROUP="$BUNDLE_ID.shared"
fi
if [ -z "$IDENTITY" ]; then
    IDENTITY="-"
    echo "WARNING: no signing identity found, so ad-hoc signing. Accessibility"
    echo "         permission will need granting again after every build."
fi

# --- The menu bar app ---------------------------------------------------------
swift build -c release
BIN="$(swift build -c release --show-bin-path)/StageLeft"

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
    <key>StageLeftAppGroup</key><string>$APP_GROUP</string>
</dict>
</plist>
PLIST

# --- The Control Centre button ------------------------------------------------
# Needs the macOS SDK matching the running OS and appintentsmetadataprocessor,
# neither of which ships with Command Line Tools.
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
    TRIPLE="arm64-apple-macos$SDK_VERSION"
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
        --deployment-target "$SDK_VERSION" \
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
    <key>LSMinimumSystemVersion</key><string>$SDK_VERSION</string>
    <key>StageLeftAppGroup</key><string>$APP_GROUP</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string>
    </dict>
</dict>
</plist>
PLIST
    rm -rf "$WORK"
    echo "Built Control Centre extension (SDK $SDK_VERSION, Xcode $XCODE_BUILD)"
else
    echo "Skipping Control Centre extension (needs Xcode — see README)"
fi

# --- Sign ---------------------------------------------------------------------
# Entitlements are templates: the app group is filled in here.
mkdir -p build/entitlements
sed "s/__APP_GROUP__/$APP_GROUP/g" StageLeft.entitlements > build/entitlements/StageLeft.entitlements
sed "s/__APP_GROUP__/$APP_GROUP/g" Extension/Controls.entitlements > build/entitlements/Controls.entitlements

# Nested code is signed inside out, so the app's seal covers the extension.
[ -d "$APPEX" ] && codesign --force --sign "$IDENTITY" --timestamp=none \
    --entitlements build/entitlements/Controls.entitlements "$APPEX"
codesign --force --sign "$IDENTITY" --timestamp=none \
    --entitlements build/entitlements/StageLeft.entitlements "$APP"
codesign --verify --strict --deep "$APP"

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
