#!/usr/bin/env bash
# After xcodegen, base.yml merges paid capabilities into Personal entitlements.
# Free Apple team cannot sign those — rewrite to app-group only.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GROUP="group.8M4N6TKXG7.com.claudiorocha.openglasses"
for f in \
  "$ROOT/Config/Entitlements/Personal/OpenGlasses.entitlements" \
  "$ROOT/Config/Entitlements/Personal/GlassesActivityWidget.entitlements" \
  "$ROOT/Config/Entitlements/Personal/OpenGlassesShareExtension.entitlements"
do
  mkdir -p "$(dirname "$f")"
  cat >"$f" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>${GROUP}</string>
	</array>
</dict>
</plist>
ENT
done
echo "Forced free-tier entitlements (app group ${GROUP})"
