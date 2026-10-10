#!/bin/bash
# screensets installer
#
#   From a clone:   ./install.sh
#   One-liner:      curl -fsSL https://raw.githubusercontent.com/rubo88/screensets/main/install.sh | bash
#
# Builds screensets from source, installs it to ~/.local/bin, creates a starter config if there is
# none, and registers a LaunchAgent so it starts at login. Re-running it updates an existing install.
set -euo pipefail

REPO="rubo88/screensets"
BRANCH="${SCREENSETS_BRANCH:-main}"
LABEL="io.github.rubo88.screensets"
BIN_DIR="$HOME/.local/bin"
BIN="$BIN_DIR/screensets"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/screensets.log"
DOMAIN="gui/$(id -u)"

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "screensets only runs on macOS."

if ! xcrun --find swiftc >/dev/null 2>&1; then
    die "The Swift compiler was not found. Install Apple's Command Line Tools with
       xcode-select --install
and run this installer again."
fi

# --- source: the clone this script lives in, or a fresh download ---
SRC_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "$(dirname "${BASH_SOURCE[0]}")/screensets.swift" ]; then
    SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    say "Downloading source ($REPO@$BRANCH)…"
    curl -fsSL "https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz" | tar -xz -C "$TMP"
    SRC_DIR="$(find "$TMP" -maxdepth 1 -mindepth 1 -type d | head -1)"
    [ -f "$SRC_DIR/screensets.swift" ] || die "Download failed: screensets.swift not found."
fi

# --- build ---
say "Building…"
BUILD_DIR="$(mktemp -d)"
xcrun swiftc -O "$SRC_DIR/screensets.swift" -o "$BUILD_DIR/screensets" \
    -F /System/Library/PrivateFrameworks -framework CoreDisplay
"$BUILD_DIR/screensets" version >/dev/null || die "The build does not run."

# --- stop a running instance before replacing the binary ---
if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    say "Stopping the running instance…"
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    sleep 1
fi

# --- install binary (rm first: overwriting in place keeps macOS's cached code signature
#     for that inode and the new binary gets killed at launch) ---
mkdir -p "$BIN_DIR"
rm -f "$BIN"
cp "$BUILD_DIR/screensets" "$BIN"
rm -rf "$BUILD_DIR"
say "Installed $BIN"

# --- starter config (never overwrites an existing one) ---
"$BIN" init

# --- LaunchAgent ---
mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$BIN</string><string>daemon</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
launchctl bootstrap "$DOMAIN" "$PLIST"

# --- check ---
sleep 2
if launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -q "state = running"; then
    say "screensets is running (it will start automatically at login)."
else
    warn "screensets did not start. Check $LOG"
    exit 1
fi

if pgrep -fq "SwitchResX Daemon"; then
    warn "SwitchResX is running: its hotkeys may clash with screensets. Quit it and remove it from Login Items."
fi
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) warn "$BIN_DIR is not in your PATH. Add this to ~/.zshrc to use the 'screensets' command:
       export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

echo
echo "Displays:"
"$BIN" list
echo
echo "Hotkeys ($(grep -o '"modifiers": *"[^"]*"' "$HOME/.config/screensets/sets.json" | cut -d'"' -f4) + key):"
"$BIN" sets
echo
echo "Edit your sets in ~/.config/screensets/sets.json — see https://github.com/$REPO#configuration"
