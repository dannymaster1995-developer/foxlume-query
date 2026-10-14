#!/bin/bash
# Build "Foxlume Query.app" (release, Apple silicon) into build/.
# Uses only the Command Line Tools; every cache stays inside the project folder (see scripts/env.sh).
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/env.sh
[ -f Vendor/duckdb/libduckdb.dylib ] || scripts/fetch-duckdb.sh

VERSION="${FOXLUME_VERSION:-0.1.0}"
BUILD_NUMBER="${FOXLUME_BUILD:-1}"
CONFIGURATION="${1:-release}"

fqswift build -c "$CONFIGURATION" --product FoxlumeQuery
BIN="$(HOME="$FQ_HOME" CFFIXED_USER_HOME="$FQ_HOME" swift build "${FQ_SWIFTPM_FLAGS[@]}" -c "$CONFIGURATION" --show-bin-path)/FoxlumeQuery"

APP="$FQ_PROJECT/build/Foxlume Query.app"
EXE="$APP/Contents/MacOS/FoxlumeQuery"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$EXE"

# DuckDB is linked as @rpath/libduckdb.dylib. Ship it in Contents/Frameworks and swap the development
# rpath (Vendor/duckdb, added by Package.swift) for one relative to the executable.
cp "$FQ_PROJECT/Vendor/duckdb/libduckdb.dylib" "$APP/Contents/Frameworks/libduckdb.dylib"
otool -l "$EXE" | awk '/cmd LC_RPATH/ { getline; getline; print $2 }' | while read -r rpath; do
  case "$rpath" in
    */Vendor/duckdb) install_name_tool -delete_rpath "$rpath" "$EXE" ;;
  esac
done
install_name_tool -add_rpath "@executable_path/../Frameworks" "$EXE"

# Icon: render PNGs from the app's own drawing code, then pack them with iconutil.
ICONSET="$FQ_PROJECT/build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  "$BIN" --export-icon "$ICONSET/icon_${size}x${size}.png" "$size"
  "$BIN" --export-icon "$ICONSET/icon_${size}x${size}@2x.png" "$((size * 2))"
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# License texts travel with the app: ours (AGPL) and DuckDB's (MIT requires its notice in every copy).
cp "$FQ_PROJECT/LICENSE" "$APP/Contents/Resources/LICENSE"
cp "$FQ_PROJECT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp "$FQ_PROJECT/Vendor/duckdb/LICENSE" "$APP/Contents/Resources/DUCKDB_LICENSE"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>FoxlumeQuery</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>com.foxlume.query</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Foxlume Query</string>
  <key>CFBundleDisplayName</key><string>Foxlume Query</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 the Foxlume Query contributors. AGPL-3.0-or-later.</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>com.foxlume.query.database-url</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>postgresql</string><string>postgres</string><string>mysql</string><string>mariadb</string>
        <string>mongodb</string><string>mongodb+srv</string><string>redis</string><string>rediss</string>
        <string>sqlite</string><string>duckdb</string>
      </array>
    </dict>
  </array>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>SQLite Database</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>CFBundleTypeExtensions</key>
      <array><string>sqlite</string><string>sqlite3</string><string>db</string><string>db3</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>DuckDB Database</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>CFBundleTypeExtensions</key>
      <array><string>duckdb</string><string>ddb</string><string>parquet</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>SQL File</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>CFBundleTypeExtensions</key>
      <array><string>sql</string><string>psql</string><string>pgsql</string></array>
    </dict>
  </array>
</dict>
</plist>
EOF
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Nested code is signed before the bundle that contains it.
codesign --force --sign - --timestamp=none "$APP/Contents/Frameworks/libduckdb.dylib" >/dev/null
codesign --force --sign - --timestamp=none "$APP" >/dev/null
echo "Built $APP ($(du -sh "$APP" | cut -f1))"
