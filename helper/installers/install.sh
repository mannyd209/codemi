#!/bin/sh
# CodeMi Helper installer for macOS.
#   curl -fsSL https://<relay>/install.sh | sh -s -- <pairing-secret> <helper-sha256>
# The CodeMi app passes the SHA-256 of the helper it expects, so the download is checked against
# a value from the app, not from this server. About the helper: https://mannydlabs.com/codemi-helper
# Installs a small background helper that lets the CodeMi iPhone app check Kimi Code's
# Remote Control and turn it back on. It never runs any other command.
# Uninstall: curl -fsSL https://<relay>/install.sh | sh -s -- --uninstall
set -eu

RELAY="${CODEMI_RELAY:-https://relay.mannydlabs.com}"
LABEL="com.mannydlabs.codemi.helper"
DIR="$HOME/Library/Application Support/CodeMi Helper"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/CodeMi Helper.log"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "This installer is for macOS. On Windows, use install.ps1." >&2
  exit 1
fi

if [ "${1:-}" = "--uninstall" ]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  rm -rf "$DIR"
  echo "CodeMi Helper removed."
  exit 0
fi

SECRET="${1:-}"
PINNED="${2:-}"
case "$SECRET" in
  ???????????????????????????????????????????) ;;
  *) echo "Usage: sh install.sh <pairing-secret from the CodeMi app>" >&2; exit 1 ;;
esac

mkdir -p "$DIR" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

curl -fsSL "$RELAY/helper/mac/codemi-helper.zip" -o "$TMP/helper.zip"
if [ -n "$PINNED" ]; then
  EXPECTED="$PINNED"
else
  EXPECTED="$(curl -fsSL "$RELAY/helper/mac/codemi-helper.sha256" | cut -d' ' -f1)"
fi
ACTUAL="$(shasum -a 256 "$TMP/helper.zip" | cut -d' ' -f1)"
# An older CodeMi app pins the helper version it shipped with (newest first).
for OLDER in 0.3.1 0.3.0 0.2.1; do
  [ "$ACTUAL" = "$EXPECTED" ] && break
  curl -fsSL "$RELAY/helper/mac/$OLDER/codemi-helper.zip" -o "$TMP/helper.zip"
  ACTUAL="$(shasum -a 256 "$TMP/helper.zip" | cut -d' ' -f1)"
done
if [ "$ACTUAL" != "$EXPECTED" ]; then
  echo "Download check failed (SHA-256 $ACTUAL, expected $EXPECTED); nothing was installed." >&2
  exit 1
fi
echo "Helper download verified (SHA-256 $ACTUAL)."

ditto -x -k "$TMP/helper.zip" "$TMP/unzipped"
codesign --verify --strict "$TMP/unzipped/codemi-helper"

# Already installed and identical to the verified download: nothing to replace, only this
# device's pairing to add. An older copy is updated.
if [ -f "$DIR/codemi-helper" ] && cmp -s "$DIR/codemi-helper" "$TMP/unzipped/codemi-helper"; then
  echo "CodeMi Helper is already installed and up to date. Linking this device."
  UP_TO_DATE=1
else
  [ -f "$DIR/codemi-helper" ] && echo "An older CodeMi Helper is installed; updating it."
  UP_TO_DATE=0
fi

# Keep the pairings other iPhones and iPads already have (pairing codes are 43 characters):
# this one first, then up to 7 earlier ones.
LIST="\"$SECRET\""
if [ -f "$DIR/config.json" ]; then
  for OLD in $(grep -o '"[A-Za-z0-9_-]\{43\}"' "$DIR/config.json" | tr -d '"' | grep -v -x -- "$SECRET" | awk '!seen[$0]++' | head -n 7); do
    LIST="$LIST,\"$OLD\""
  done
fi

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
# Make sure the old helper (with its old pairing) has really stopped.
pkill -f "$DIR/codemi-helper" 2>/dev/null || true
# A fresh log, so the check below only counts the new helper connecting.
: > "$LOG"
[ "$UP_TO_DATE" = 1 ] || mv -f "$TMP/unzipped/codemi-helper" "$DIR/codemi-helper"
umask 077
printf '{"relay":"%s","secret":"%s","secrets":[%s]}\n' "$RELAY" "$SECRET" "$LIST" > "$DIR/config.json"
umask 022

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$DIR/codemi-helper</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>ProcessType</key><string>Background</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF

launchctl bootstrap "gui/$(id -u)" "$PLIST"
i=0
while [ $i -lt 20 ]; do
  if grep -q "Connected to relay" "$LOG" 2>/dev/null; then
    echo "CodeMi Helper is installed, running and linked. You can turn Remote Control back on from the CodeMi app."
    exit 0
  fi
  sleep 1
  i=$((i + 1))
done
echo "CodeMi Helper was installed but hasn't connected yet. Log: $LOG" >&2
exit 1
