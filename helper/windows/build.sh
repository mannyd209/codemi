#!/bin/bash
# Copies the Windows CodeMi Helper (a PowerShell script) and its checksum into ../relay/public/helper/windows.
set -euo pipefail
cd "$(dirname "$0")"
OUT=../relay/public/helper/windows
mkdir -p "$OUT"
cp helper.ps1 "$OUT/helper.ps1"
shasum -a 256 "$OUT/helper.ps1" | cut -d' ' -f1 > "$OUT/helper.sha256"
echo "Packaged: $OUT/helper.ps1 ($(cut -c1-12 "$OUT/helper.sha256")…)"
