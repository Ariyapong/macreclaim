#!/usr/bin/env bash
# macreclaim release — make freed space actually visible.
#
# On APFS, deleting files often frees nothing you can see: blocks referenced by
# Time Machine LOCAL snapshots become "purgeable", not free. This drops those
# snapshots and reports anything still held open by a running process.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$DIR/lib/common.sh"
mr_require_macos

YES=0
[ "${1:-}" = "--yes" ] && YES=1

hdr "SPACE BEFORE"
mr_free
mr_purgeable
info "df Avail EXCLUDES purgeable space; Container Free Space INCLUDES it."
info "A large gap between the two means snapshots are holding your deletions."

hdr "LOCAL SNAPSHOTS"
SNAPS=$(tmutil listlocalsnapshots / 2>/dev/null | grep -o '[0-9]\{4\}-[0-9][0-9]-[0-9][0-9]-[0-9]\{6\}')
if [ -z "$SNAPS" ]; then
  ok "None. Nothing is being held by snapshots."
else
  echo "$SNAPS" | sed 's/^/  /'
  echo
  info "These are macOS's automatic on-disk restore points."
  info "Time Machine backups on an external or network drive are NOT affected."
  info "macOS recreates local snapshots on its own schedule."
  echo
  if [ "$YES" != "1" ]; then
    printf "  Delete these local snapshots? [y/N] "
    read -r ans
    case "$ans" in y|Y|yes|YES) ;; *) warn "Skipped."; SNAPS="" ;; esac
  fi
  if [ -n "$SNAPS" ]; then
    hdr "DELETING SNAPSHOTS (requires sudo)"
    for s in $SNAPS; do
      info "deleting $s"
      sudo tmutil deletelocalsnapshots "$s" 2>&1 | sed 's/^/    /'
    done
    info "--- thin pass ---"
    sudo tmutil thinlocalsnapshots / 100000000000 4 2>&1 | sed 's/^/    /'
  fi
fi

hdr "DELETED FILES STILL HELD OPEN"
info "Space stays locked until these processes exit. A reboot clears all of them."
info "Ignore LaunchServices / .csstore entries — macOS rotates those constantly."
# -F field output instead of columns: NAMEs with spaces survive, a missing SIZE
# can't shift fields, and +c 0 stops lsof truncating COMMAND to 9 chars.
# One line per (command, file); "(xN)" = how many descriptors/processes hold it.
sudo lsof -nP +c 0 +L1 -F csn 2>/dev/null \
  | awk '
      /^c/ { cmd = substr($0, 2) }
      /^f/ { size = 0 }
      /^s/ { size = substr($0, 2) + 0 }
      /^n/ { name = substr($0, 2)
             if (size > 10485760 && name !~ /\.csstore/ && name !~ /LaunchServices/)
               printf "%s\t%s\t%s\n", size, cmd, name
             size = 0 }' \
  | sort | uniq -c | sort -k2,2nr | head -15 \
  | awk '{ n = $1; sub(/^ *[0-9]+ /, ""); split($0, a, "\t")
           printf "  %-24s %8.1f MB  %s%s\n", a[2], a[1]/1048576, a[3], (n > 1 ? "  (x" n ")" : "") }'
echo "  (only entries over 10 MB shown)"

hdr "SPACE AFTER"
sleep 5
mr_free
mr_purgeable

hdr "DONE"
ok "If Avail is still low, reboot once — that releases every held-open file."
