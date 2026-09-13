#!/usr/bin/env bash
# macreclaim drill — read-only, targeted sizing of the big unknowns. ~1 minute.
# Usage: macreclaim drill [extra/paths ...]
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export NO_COLOR=1   # output goes to a file; colour must be decided before common.sh loads
. "$DIR/lib/common.sh"
mr_require_macos

OUTDIR="${MACRECLAIM_OUT:-$PWD/reports}"
mkdir -p "$OUTDIR"
OUT="$OUTDIR/drill-$(date +%Y%m%d-%H%M%S).txt"

EXTRA=("$@")

echo "Drilling into the largest directories… ~1 minute."
echo "  $OUT"
echo

exec > "$OUT" 2>&1
export LC_ALL=C
H="$HOME"

echo "macreclaim drill — $(date)"

hdr "SPACE"
mr_free
mr_purgeable
echo "  (df Avail EXCLUDES purgeable; Container Free Space INCLUDES it)"

# Auto-pick the biggest children of the usual suspects and expand them.
AUTO="$H/Library/Group Containers
$H/Library/Application Support
$H/Library/Caches
$H/Library/Containers
$H/.cache
$H/.npm
$H/Library/pnpm
$H/.nuget
$H/.local"

echo "$AUTO" | while IFS= read -r base; do
  [ -d "$base" ] || continue
  hdr "$(tilde "$base")  (depth 2)"
  du -xh -d 2 "$base" 2>/dev/null | sort -hr | head -25
done

hdr "ms-playwright browser revisions"
du -xh -d 1 "$H/Library/Caches/ms-playwright" 2>/dev/null | sort -hr

hdr "nvm node versions"
du -xh -d 1 "$H/.nvm/versions/node" 2>/dev/null | sort -hr
echo "--- default alias: $(cat "$H/.nvm/alias/default" 2>/dev/null) / current: $(node -v 2>/dev/null) ---"

hdr "pnpm store versions (only the newest is in use)"
du -xh -d 1 "$H/Library/pnpm/store" "$H/.pnpm-store" 2>/dev/null | sort -hr

hdr "Homebrew"
du -xh -d 1 /opt/homebrew 2>/dev/null | sort -hr | head -10
if command -v brew >/dev/null 2>&1; then
  BC=$(brew cleanup -n 2>/dev/null | tail -3)
  if [ -n "$BC" ]; then echo "$BC"; else echo "brew cleanup -n: nothing to remove"; fi
fi

hdr "VS Code family — cache vs. real data"
for v in "Code" "Code - Insiders" "VSCodium" "Cursor"; do
  [ -d "$H/Library/Application Support/$v" ] || continue
  echo "--- $v ---"
  du -xh -d 1 "$H/Library/Application Support/$v" 2>/dev/null | sort -hr | head -12
done

hdr "Editor extensions"
for e in "$H/.vscode/extensions" "$H/.vscode-insiders/extensions" "$H/.cursor/extensions"; do
  [ -d "$e" ] || continue
  echo "--- $(tilde "$e") ---"
  du -xh -d 1 "$e" 2>/dev/null | sort -hr | head -12
done

hdr "Downloads — largest loose files"
ls -lhS "$H/Downloads" 2>/dev/null | head -30

if [ "${#EXTRA[@]}" -gt 0 ]; then
  for p in "${EXTRA[@]}"; do
    hdr "EXTRA: $p"
    du -xh -d 2 "$p" 2>/dev/null | sort -hr | head -25
  done
fi

hdr "DONE"
date
