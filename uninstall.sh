#!/bin/bash
# screensets uninstaller
#
#   ./uninstall.sh            removes the app and its LaunchAgent, keeps your config and log
#   ./uninstall.sh --purge    also removes ~/.config/screensets and the log
set -euo pipefail

LABEL="io.github.rubo88.screensets"
DOMAIN="gui/$(id -u)"

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null && echo "Stopped screensets." || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist" "$HOME/.local/bin/screensets"
echo "Removed the app and its LaunchAgent."

if [ "${1:-}" = "--purge" ]; then
    rm -rf "$HOME/.config/screensets" "$HOME/Library/Logs/screensets.log"
    echo "Removed ~/.config/screensets and the log."
else
    echo "Kept your sets in ~/.config/screensets (use --purge to remove them)."
fi
echo "Displays turned off by screensets come back on at the next logout or restart."
