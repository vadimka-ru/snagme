#!/bin/bash
# Сборка SnagMe.app из SwiftPM-бинарника (без Xcode).
# Кладёт готовый .app на рабочий стол.
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="SnagMe"
DEST="$HOME/Desktop/$APP_NAME.app"

echo "→ Сборка release-бинарника…"
cd "$PROJECT_DIR"
swift build -c release

# Генерация AppIcon.icns из AppIcon.png (если есть).
if [ -f "$PROJECT_DIR/AppIcon.png" ]; then
    echo "→ Генерация AppIcon.icns"
    rm -rf "$PROJECT_DIR/AppIcon.iconset"
    mkdir "$PROJECT_DIR/AppIcon.iconset"
    for s in 16 32 128 256 512; do
        d=$((s * 2))
        sips -z $s $s "$PROJECT_DIR/AppIcon.png" --out "$PROJECT_DIR/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null 2>&1
        sips -z $d $d "$PROJECT_DIR/AppIcon.png" --out "$PROJECT_DIR/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null 2>&1
    done
    iconutil -c icns "$PROJECT_DIR/AppIcon.iconset" -o "$PROJECT_DIR/AppIcon.icns"
    rm -rf "$PROJECT_DIR/AppIcon.iconset"
fi

echo "→ Сборка бандла $DEST"
rm -rf "$DEST"
mkdir -p "$DEST/Contents/MacOS"
mkdir -p "$DEST/Contents/Resources"

cp "$PROJECT_DIR/.build/release/$APP_NAME" "$DEST/Contents/MacOS/$APP_NAME"
cp "$PROJECT_DIR/Sources/SnagMe/Resources/Info.plist" "$DEST/Contents/Info.plist"
# SVG-иконки в SwiftPM resource-бандле. Bundle.module ищет его в Bundle.main.resourceURL
# (= Contents/Resources). Кладём ТОЛЬКО туда — бандл в Contents/MacOS ломает codesign
# («code has no resources but signature indicates they must be present»).
cp -R "$PROJECT_DIR/.build/release/${APP_NAME}_${APP_NAME}.bundle" "$DEST/Contents/Resources/"
cp "$PROJECT_DIR/AppIcon.icns" "$DEST/Contents/Resources/AppIcon.icns"

# Подпись: стабильная самоподписанная "SnagMe Dev" (если есть) → разрешения держатся
# между пересборками. Иначе ad-hoc (разрешения слетают на каждом билде).
IDENTITY="SnagMe Dev"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "→ Подпись: $IDENTITY (стабильная)"
    codesign --force --deep --sign "$IDENTITY" "$DEST" 2>/dev/null || true
else
    echo "→ Подпись: ad-hoc (создай '$IDENTITY' в Keychain, чтобы разрешения не слетали)"
    codesign --force --deep --sign - "$DEST" 2>/dev/null || true
fi

echo "✓ Готово: $DEST"
