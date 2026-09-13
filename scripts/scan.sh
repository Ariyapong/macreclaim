#!/usr/bin/env bash
# macreclaim scan — read-only full audit. Deletes nothing, changes nothing.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export NO_COLOR=1   # output goes to a file; colour must be decided before common.sh loads
. "$DIR/lib/common.sh"
mr_require_macos

OUTDIR="${MACRECLAIM_OUT:-$PWD/reports}"
mkdir -p "$OUTDIR"
OUT="$OUTDIR/scan-$(date +%Y%m%d-%H%M%S).txt"

: "${MR_BIG_FILE_MB:=200}"
: "${MR_NODE_MODULES_MB:=100}"
: "${MR_REPO_MB:=300}"

echo "Scanning… this walks your whole home folder and takes 3-10 minutes."
echo "Nothing is printed until it finishes. Writing to:"
echo "  $OUT"
echo

exec > "$OUT" 2>&1
export LC_ALL=C
H="$HOME"
FERR=$(mktemp -t macreclaim-find) || FERR=/dev/null
# find_errs — say so when a walk skipped things; a silent partial walk looks
# exactly like a clean one otherwise.
find_errs() {
  [ -s "$FERR" ] || return 0
  printf "  (find reported %s unreadable entries; first: %s)\n" "$(wc -l < "$FERR" | tr -d ' ')" "$(head -1 "$FERR")"
  : > "$FERR"
}

echo "macreclaim scan — $(date)"
echo "host=$(hostname)  user=$USER  macOS=$(sw_vers -productVersion 2>/dev/null)"

hdr "VOLUMES"
df -h / /System/Volumes/Data 2>/dev/null
echo
diskutil info / 2>/dev/null | grep -Ei 'Volume Name|Container Free|Disk Size'

hdr "LOCAL SNAPSHOTS (hold deleted blocks as purgeable)"
SNAPS=$(tmutil listlocalsnapshots / 2>/dev/null | grep -v '^Snapshots for disk')
if [ -n "$SNAPS" ]; then echo "$SNAPS" | tail -25; else echo "(none — local snapshots only exist while Time Machine is enabled)"; fi

hdr "HOME TOP-LEVEL"
du -xh -d 1 "$H" 2>/dev/null | sort -hr | head -60

for d in "Library" "Library/Caches" "Library/Application Support" \
         "Library/Containers" "Library/Group Containers" "Library/Developer"; do
  [ -d "$H/$d" ] || continue
  hdr "~/$d"
  du -xh -d 1 "$H/$d" 2>/dev/null | sort -hr | head -30
done

hdr "/Applications (size)"
du -xh -d 1 /Applications 2>/dev/null | sort -hr | head -60

hdr "/Applications (size + last opened, oldest first)"
echo "NOTE: a (null) date means Spotlight has no record — NOT proof the app is unused."
for a in /Applications/*.app; do
  [ -e "$a" ] || continue
  d=$(mdls -name kMDItemLastUsedDate -raw "$a" 2>/dev/null)
  s=$(du -sm "$a" 2>/dev/null | cut -f1)
  printf "%8s MB  %-12s  %s\n" "${s:-?}" "${d:0:10}" "$(basename "$a")"
done | sort -k3,3

hdr "DEV CACHES"
for p in "$H/.npm" "$H/.pnpm-store" "$H/Library/pnpm" "$H/.yarn" "$H/Library/Caches/Yarn" \
         "$H/.cache" "$H/.cache/uv" "$H/.cache/node/corepack" "$H/Library/Caches/pnpm" \
         "$H/.local/share/NuGet" "$H/.nvm" "$H/.bun" "$H/.deno" "$H/.cargo" "$H/.rustup" "$H/go" \
         "$H/.gradle" "$H/.m2" "$H/.cocoapods" "$H/Library/Caches/CocoaPods" \
         "$H/Library/Caches/Homebrew" "$H/Library/Caches/pip" "$H/.dotnet" "$H/.nuget" \
         "$H/.sonar" "$H/.sonarlint" "$H/.pyenv" "$H/.conda" "$H/.gem" "$H/.composer" \
         "$H/.docker" "$H/.colima" "$H/.orbstack" "$H/.lima" "$H/.podman" "$H/.vagrant.d" \
         "$H/Library/Caches/ms-playwright" "$H/Library/Caches/puppeteer" \
         "$H/Library/Caches/electron" "$H/Library/Caches/typescript" \
         "$H/.vscode/extensions" "$H/.vscode-insiders/extensions" "$H/.cursor/extensions" \
         "$H/.Trash"; do
  [ -e "$p" ] && du -sh "$p" 2>/dev/null
done | sort -hr

hdr "HOMEBREW"
du -sh /opt/homebrew /usr/local/Homebrew 2>/dev/null
if command -v brew >/dev/null 2>&1; then
  BC=$(brew cleanup -n 2>/dev/null | tail -3)
  if [ -n "$BC" ]; then echo "$BC"; else echo "brew cleanup -n: nothing to remove"; fi
fi

hdr "CONTAINERS / VMs"
du -sh "$H/Library/Containers/com.docker.docker" "$H/.docker/desktop" "$H/.colima" \
       "$H/.orbstack" "$H/.lima" "$H/Virtual Machines.localized" \
       "$H/Library/Containers/com.utmapp.UTM" 2>/dev/null
docker system df 2>/dev/null

hdr "ELECTRON APP PARTITIONS (often the biggest single items)"
find "$H/Library/Application Support" -maxdepth 2 -type d -name Partitions 2>/dev/null | while read -r d; do
  m=$(du -sm "$d" 2>/dev/null | cut -f1); [ "${m:-0}" -ge 200 ] && printf "%8s MB  %s\n" "$m" "$d"
done | sort -nr

hdr "node_modules >= ${MR_NODE_MODULES_MB}MB"
find "$H" -maxdepth 7 -type d -name node_modules -prune 2>>"$FERR" | while read -r d; do
  m=$(du -sm "$d" 2>>"$FERR" | cut -f1)
  [ "${m:-0}" -ge "$MR_NODE_MODULES_MB" ] && printf "%8s MB  %s\n" "$m" "$d"
done | sort -nr | head -40
find_errs

hdr "BUILD / TEST DIRS >= ${MR_NODE_MODULES_MB}MB"
find "$H" -maxdepth 7 -type d -name node_modules -prune -o -type d \( -name .next -o -name dist \
     -o -name build -o -name target -o -name venv -o -name .venv -o -name .turbo -o -name DerivedData \
     -o -name .vscode-test -o -name .gradle -o -name .tox \) -prune -print 2>>"$FERR" | while read -r d; do
  m=$(du -sm "$d" 2>>"$FERR" | cut -f1)
  [ "${m:-0}" -ge "$MR_NODE_MODULES_MB" ] && printf "%8s MB  %s\n" "$m" "$d"
done | sort -nr | head -40
find_errs

hdr "GIT REPOS >= ${MR_REPO_MB}MB (with last commit date)"
find "$H" -maxdepth 6 -type d -name .git -prune 2>>"$FERR" | while read -r g; do
  r=$(dirname "$g")
  m=$(du -sm "$r" 2>/dev/null | cut -f1)
  [ "${m:-0}" -ge "$MR_REPO_MB" ] || continue
  last=$(git -C "$r" log -1 --format=%cd --date=short 2>/dev/null)
  nm=0; [ -d "$r/node_modules" ] && nm=$(du -sm "$r/node_modules" 2>/dev/null | cut -f1)
  printf "%-12s  total:%7sMB  node_modules:%7sMB  %s\n" "${last:-no-commits}" "$m" "${nm:-0}" "$r"
done | sort
find_errs

hdr "FILES >= ${MR_BIG_FILE_MB}MB IN HOME  (allocated size — sparse disk images show what they really use)"
find "$H" -type f -size +$((MR_BIG_FILE_MB * 1000))k -exec du -sm {} + 2>>"$FERR" \
  | sort -nr | head -60 | awk -F'\t' '{printf "%8s MB  %s\n", $1, $2}'
find_errs

hdr "USER FOLDERS"
for d in Downloads Desktop Documents Movies Pictures Music; do
  [ -d "$H/$d" ] || continue
  echo "--- ~/$d ---"
  du -xh -d 1 "$H/$d" 2>/dev/null | sort -hr | head -15
done

hdr "MAIL / MESSAGING / PHOTOS  (data, not cache — do not delete blindly)"
du -sh "$H/Library/Mail" "$H/Library/Messages" \
       "$H/Library/Application Support/MobileSync/Backup" \
       "$H/Pictures/Photos Library.photoslibrary" 2>/dev/null
du -sh "$H/Library/Group Containers/"*Office "$H/Library/Group Containers/"*line* 2>/dev/null

hdr "DONE"
date
[ "$FERR" != /dev/null ] && rm -f "$FERR"
