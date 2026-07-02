#!/bin/zsh
# Build vk01d.app — the VK-01 knob daemon as a menu bar app.
set -e
cd "$(dirname "$0")"
mkdir -p vk01d.app/Contents/MacOS
cat > vk01d.app/Contents/Info.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.frostvalley.vk01d</string>
    <key>CFBundleName</key><string>vk01d</string>
    <key>CFBundleExecutable</key><string>vk01d</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
EOF
swiftc vk01d.swift -o vk01d.app/Contents/MacOS/vk01d
# Prefer a stable Apple Development identity (keeps TCC grants across rebuilds); ad-hoc if none.
identity=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
codesign --force --sign "${identity:--}" vk01d.app
echo "Signed as: ${identity:-ad-hoc}"
echo "Built vk01d.app — launch with: open vk01d.app"
