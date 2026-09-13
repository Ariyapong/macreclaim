#!/usr/bin/env bash
# macreclaim diff — what changed between two scan (or drill) reports.
#
#   macreclaim diff                  the two newest scan reports in ./reports
#   macreclaim diff OLD NEW          any two reports
#   macreclaim diff --min 500 ...    only show changes of 500 MB or more (default 100)
#
# Read-only. Sizes in a report are rounded (du -h prints "130G" for anything
# from 129.5 to 130.5 GB), so a change is only reported when it is bigger
# than the rounding of both numbers put together.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$DIR/lib/common.sh"

MIN_MB=100
while [ $# -gt 0 ]; do
  case "$1" in
    --min)   MIN_MB="$2"; shift 2 ;;
    --min=*) MIN_MB="${1#*=}"; shift ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) err "unknown option: $1"; exit 2 ;;
    *) break ;;
  esac
done

OLD="${1:-}"; NEW="${2:-}"
if [ -z "$OLD" ]; then
  OUTDIR="${MACRECLAIM_OUT:-$PWD/reports}"
  # newest two scan reports; the glob sorts by name, and names carry the timestamp
  for f in "$OUTDIR"/scan-*.txt; do
    [ -f "$f" ] || continue
    OLD="$NEW"; NEW="$f"
  done
  if [ -z "$OLD" ]; then
    err "need two scan reports in $OUTDIR (or pass OLD NEW explicitly)"
    exit 1
  fi
fi
for f in "$OLD" "$NEW"; do
  [ -f "$f" ] || { err "not a file: $f"; exit 1; }
done

# extract FILE -> "path<TAB>mb<TAB>precision_mb", first occurrence of each path wins
extract() {
  awk -v home="$HOME" '
    function emit(path, mb, prec) {
      if (path ~ "^" home "/") path = "~" substr(path, length(home) + 1)
      else if (path == home) path = "~"
      if (!(path in seen)) { seen[path] = 1; printf "%s\t%.3f\t%.3f\n", path, mb, prec }
    }
    # du -h lines:  "130G<TAB>/path"  "4.3G<TAB>/path"  "500M<TAB>/path"
    /^[ \t]*[0-9.]+[BKMGT]i?[ \t]+\// {
      n = split($0, f, /[ \t]+/); i = (f[1] == "") ? 2 : 1
      size = f[i]; path = $0
      sub(/^[ \t]*[0-9.]+[BKMGT]i?[ \t]+/, "", path)
      unit = substr(size, length(size)); sub(/i$/, "", unit)
      if (unit == "i") { unit = substr(size, length(size) - 1, 1); num = substr(size, 1, length(size) - 2) }
      else num = substr(size, 1, length(size) - 1)
      mult = (unit == "B") ? 1/1048576 : (unit == "K") ? 1/1024 : (unit == "M") ? 1 : (unit == "G") ? 1024 : 1048576
      prec = (num ~ /\./) ? 0.05 * mult : 0.5 * mult
      emit(path, num * mult, prec); next
    }
    # macreclaim table lines:  "   22000 MB  /path"  "  966 MB  2026-01-01    Chrome.app"
    /^[ \t]*[0-9]+ MB  / {
      mb = $1; rest = $0; sub(/^[ \t]*[0-9]+ MB  /, "", rest)
      n = split(rest, c, /  +/); path = c[n]
      if (path ~ /^\(/) next            # "(find reported ...)" style notes
      emit(path, mb, 0.5); next
    }
  ' "$1"
}

avail() { awk '/\/System\/Volumes\/Data/ && $4 ~ /[KMGT]i$/ { print $4; exit }' "$1"; }

hdr "DIFF"
info "old: $(tilde "$OLD")"
info "new: $(tilde "$NEW")"
a1=$(avail "$OLD"); a2=$(avail "$NEW")
[ -n "$a1$a2" ] && info "df Avail: ${a1:-?} -> ${a2:-?}"
echo

T1=$(mktemp -t macreclaim-diff) && T2=$(mktemp -t macreclaim-diff) || exit 1
trap 'rm -f "$T1" "$T2"' EXIT
extract "$OLD" > "$T1"
extract "$NEW" > "$T2"

# Join on path; print "|delta| TAB line" so we can sort by magnitude.
awk -F'\t' -v min="$MIN_MB" '
  function fmt(mb,   s) { s = (mb < 0) ? "-" : "+"; mb = (mb < 0) ? -mb : mb
    return (mb >= 1024) ? sprintf("%s%.1f GB", s, mb / 1024) : sprintf("%s%d MB", s, mb + 0.5) }
  function abs(mb) { return (mb < 0) ? -mb : mb }
  function human(mb) { return (mb >= 1024) ? sprintf("%.1fG", mb / 1024) : sprintf("%dM", mb + 0.5) }
  NR == FNR { old[$1] = $2; oprec[$1] = $3; next }
  {
    if ($1 in old) {
      d = $2 - old[$1]
      if (abs(d) >= min && abs(d) > oprec[$1] + $3 + 0.001)
        printf "%.3f\t%-10s %s  (%s -> %s)\n", abs(d), fmt(d), $1, human(old[$1]), human($2)
      delete old[$1]
    } else if ($2 >= min) {
      printf "%.3f\t%-10s %s  (%s)\n", $2, "new", $1, human($2)
    }
  }
  END { for (p in old) if (old[p] >= min) printf "%.3f\t%-10s %s  (was %s)\n", old[p], "gone", p, human(old[p]) }
' "$T1" "$T2" | sort -t$'\t' -k1,1nr | cut -f2- | sed 's/^/  /' > "$T1.out"

if [ -s "$T1.out" ]; then
  cat "$T1.out"
else
  info "no changes of ${MIN_MB} MB or more"
fi
rm -f "$T1.out"
echo
info "Changes under ${MIN_MB} MB, and within the rounding of the reported sizes, are not shown (--min N to adjust)."
