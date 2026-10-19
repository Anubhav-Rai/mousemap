#!/bin/bash
# Stop mousemap and remove it. Your config in ~/.config/mousemap is left alone.
set -uo pipefail

service="gui/$(id -u)/local.mousemap"
launchctl bootout "$service" 2>/dev/null
launchctl enable "$service" 2>/dev/null   # clear the "disabled" flag set by `mousemap off`
rm -f ~/Library/LaunchAgents/local.mousemap.plist ~/.local/bin/mousemap

echo "mousemap removed."
echo "Also remove \"mousemap\" from System Settings > Privacy & Security > Accessibility."
echo "Config kept at ~/.config/mousemap (delete it if you don't want it)."
