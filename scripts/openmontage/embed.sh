#!/bin/bash
set -euo pipefail
BASE="$SRCROOT/Vendor/OpenMontage"
[ -f "$BASE/runtime-version" ] || { echo 'error: Prepare OpenMontage runtime with scripts/openmontage/prepare.py first'; exit 1; }
HELPER="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers/OpenMontage Helper.app"
mkdir -p "$HELPER/Contents/MacOS" "$HELPER/Contents/Resources"
/usr/bin/ditto "$BASE/Runtime" "$HELPER/Contents/Resources/payload"
cp "$BASE/runtime-version" "$HELPER/Contents/Resources/payload-version"
mkdir -p "$DERIVED_FILE_DIR/OpenMontage"
cp "$SRCROOT/scripts/openmontage/Launcher.swift" "$DERIVED_FILE_DIR/OpenMontage/main.swift"
/usr/bin/xcrun swiftc -O "$DERIVED_FILE_DIR/OpenMontage/main.swift" "$SRCROOT/ImageAll/Application/Story/OpenMontageConfiguration.swift" -o "$HELPER/Contents/MacOS/OpenMontageHelper"
cat > "$HELPER/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.gwlee.ImageAll.OpenMontageHelper</string><key>CFBundleName</key><string>OpenMontage Helper</string><key>CFBundleExecutable</key><string>OpenMontageHelper</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>1</string><key>LSUIElement</key><true/><key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>ImageAll local engine launch</string><key>CFBundleURLSchemes</key><array><string>imageall-openmontage</string></array></dict></array></dict></plist>
PLIST
# The helper is a component of the host application identity and shares its provisioning profile.
cp "$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/embedded.provisionprofile" "$HELPER/Contents/embedded.provisionprofile"
cat > "$DERIVED_FILE_DIR/OpenMontage/helper.entitlements" <<ENTITLEMENTS
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>com.apple.application-identifier</key><string>${DEVELOPMENT_TEAM}.com.gwlee.ImageAll</string><key>com.apple.developer.team-identifier</key><string>${DEVELOPMENT_TEAM}</string><key>keychain-access-groups</key><array><string>${DEVELOPMENT_TEAM}.com.gwlee.ImageAll</string></array></dict></plist>
ENTITLEMENTS
/usr/bin/codesign --force --deep --entitlements "$DERIVED_FILE_DIR/OpenMontage/helper.entitlements" --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$HELPER"
