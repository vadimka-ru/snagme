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
cp "$PROJECT_DIR/Resources/Info.plist" "$DEST/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/Check.svg" "$DEST/Contents/Resources/Check.svg"
cp "$PROJECT_DIR/Resources/MenuIcon.svg" "$DEST/Contents/Resources/MenuIcon.svg"
cp "$PROJECT_DIR/Resources/AddFolder.svg" "$DEST/Contents/Resources/AddFolder.svg"
cp "$PROJECT_DIR/Resources/Folder.svg" "$DEST/Contents/Resources/Folder.svg"
cp "$PROJECT_DIR/Resources/ApproveFolder.svg" "$DEST/Contents/Resources/ApproveFolder.svg"
cp "$PROJECT_DIR/AppIcon.icns" "$DEST/Contents/Resources/AppIcon.icns"

# Локальная подпись (ad-hoc) — чтобы macOS не ругался при запуске.
codesign --force --deep --sign - "$DEST" 2>/dev/null || true

echo "✓ Готово: $DEST"
