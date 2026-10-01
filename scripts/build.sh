#!/bin/bash
# TV Yansit.app paketini olusturur (Xcode gerekmez, Command Line Tools yeterli).
#   ./scripts/build.sh            -> build/TV Yansıt.app (Apple Silicon + Intel)
#   ./scripts/build.sh --zip      -> ayrica dagitim icin build/TVYansit-<surum>.zip
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${VERSION:-$(cat VERSION)}"
APP="build/TV Yansıt.app"
SOURCES=(Sources/TVYansit/*.swift)

rm -rf build
mkdir -p build/arm64 build/x86_64

echo "→ Derleniyor (arm64)"
swiftc -O -parse-as-library -target arm64-apple-macos13.0 "${SOURCES[@]}" -o build/arm64/TVYansit
echo "→ Derleniyor (x86_64)"
swiftc -O -parse-as-library -target x86_64-apple-macos13.0 "${SOURCES[@]}" -o build/x86_64/TVYansit

echo "→ Paketleniyor"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create build/arm64/TVYansit build/x86_64/TVYansit -output "$APP/Contents/MacOS/TVYansit"
sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
printf "APPL????" > "$APP/Contents/PkgInfo"

# Ad-hoc imza: ekran kaydi izninin calismasi icin gerekli
codesign --force --deep --sign - "$APP"
rm -rf build/arm64 build/x86_64

if [[ "${1:-}" == "--zip" ]]; then
    ZIP="build/TVYansit-$VERSION.zip"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
    echo "→ $ZIP"
    shasum -a 256 "$ZIP"
fi

echo "✓ $APP"
