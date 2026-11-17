#!/bin/zsh
set -euo pipefail

TASK_ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
APP_BUNDLE="$TASK_ROOT/macos/.build/apps.noindex/GPT 桌宠.app"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources/assets"
mkdir -p "$TASK_ROOT/macos/.build/ModuleCache.noindex"
cp "$TASK_ROOT/macos/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$TASK_ROOT/character.json" "$APP_BUNDLE/Contents/Resources/character.json"
cp "$TASK_ROOT"/assets/*.png "$APP_BUNDLE/Contents/Resources/assets/"
mkdir -p "$APP_BUNDLE/Contents/Resources/licenses"
cp "$TASK_ROOT/LICENSE" "$TASK_ROOT/ASSET_LICENSE.md" "$APP_BUNDLE/Contents/Resources/licenses/"
if [[ -f "$TASK_ROOT/macos/AppIcon.icns" ]]; then
    cp "$TASK_ROOT/macos/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx13.0 \
    -module-cache-path "$TASK_ROOT/macos/.build/ModuleCache.noindex" \
    -framework AppKit -framework QuartzCore \
    "$TASK_ROOT/macos/CodexSelection.swift" "$TASK_ROOT/macos/main.swift" -o "$APP_BUNDLE/Contents/MacOS/GPTCompanion"
codesign --force --sign - "$APP_BUNDLE"
PLUGIN_ROOT="$TASK_ROOT/marketplace/plugins/gpt-desktop-pet"
mkdir -p "$PLUGIN_ROOT/assets"
if [[ "${GPT_PET_PACKAGE_PLUGIN:-0}" == "1" ]]; then
    mkdir -p "$PLUGIN_ROOT/app"
    ditto "$APP_BUNDLE" "$PLUGIN_ROOT/app/GPT 桌宠.app"
fi
cp "$TASK_ROOT/macos/AppIcon.png" "$PLUGIN_ROOT/assets/icon.png"
print -r -- "$APP_BUNDLE"
