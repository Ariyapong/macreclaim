#!/usr/bin/env bash
# macreclaim — shared helpers
# Targets bash 3.2 (the version macOS ships). No associative arrays, no mapfile.

MR_TOTAL_MB=0
MR_GO=${MR_GO:-0}

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_R=$'\033[31m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[1m'; C_0=$'\033[0m'
else
  C_R=''; C_G=''; C_Y=''; C_B=''; C_0=''
fi

hdr()  { printf "\n%s=========== %s ===========%s\n" "$C_Y" "$1" "$C_0"; }
info() { printf "  %s\n" "$1"; }
ok()   { printf "  %s%s%s\n" "$C_G" "$1" "$C_0"; }
warn() { printf "  %s%s%s\n" "$C_Y" "$1" "$C_0"; }
err()  { printf "  %s%s%s\n" "$C_R" "$1" "$C_0"; }

tilde()   { printf '%s' "${1/#$HOME/\~}"; }
size_mb() { du -sm "$1" 2>/dev/null | cut -f1; }
gb()      { awk -v m="$1" 'BEGIN{printf "%.1f", m/1024}'; }

# ---------------------------------------------------------------- safety
# mr_guard PATH -> 0 when the path is safe to delete, 1 otherwise.
# Deliberately paranoid: this is the only thing between a config typo and a
# very bad afternoon.
mr_guard() {
  local p="$1"
  [ -n "$p" ] || return 1
  case "$p" in *".."*) return 1 ;; esac          # no traversal
  case "$p" in *"*"*|*"?"*) return 1 ;; esac      # no unexpanded globs
  # never these, exactly
  case "$p" in
    /|"$HOME"|"$HOME"/|/Applications|/Applications/|/Users|/Users/|/Volumes|/Volumes/) return 1 ;;
    /Library|/Library/|/System|/System/*|/bin|/sbin|/usr|/etc|/var|/private|/opt) return 1 ;;
  esac
  # must live under $HOME or /Applications
  case "$p" in
    "$HOME"/*|/Applications/*) return 0 ;;
    *) return 1 ;;
  esac
}

# mr_zap PATH [LABEL] — measure, then delete when MR_GO=1
mr_zap() {
  local p="$1" mb
  if ! mr_guard "$p"; then
    err "REFUSED (failed safety check): $p"
    return 1
  fi
  if [ ! -e "$p" ]; then
    printf "  %-10s %9s  %s\n" "skip" "-" "$(tilde "$p")"
    return 0
  fi
  mb=$(size_mb "$p"); mb=${mb:-0}
  MR_TOTAL_MB=$((MR_TOTAL_MB + mb))
  if [ "$MR_GO" = "1" ]; then
    if rm -rf "$p" 2>/dev/null; then
      printf "  %s%-10s%s %6s MB  %s\n" "$C_G" "removed" "$C_0" "$mb" "$(tilde "$p")"
    else
      printf "  %s%-10s%s %6s MB  %s  (permission denied?)\n" "$C_R" "FAILED" "$C_0" "$mb" "$(tilde "$p")"
    fi
  else
    printf "  %-10s %6s MB  %s\n" "would rm" "$mb" "$(tilde "$p")"
  fi
}

# mr_keep_newest DIR PREFIX — keep only the highest-numbered DIR/PREFIX<n>
# Handles both "chromium-1243" (hyphenated) and "v11" (bare) naming.
mr_keep_newest() {
  local dir="$1" prefix="$2" newest="" n best=-1 d base
  [ -d "$dir" ] || return 0
  for d in "$dir/$prefix"*; do
    [ -d "$d" ] || continue
    base=$(basename "$d")
    n=${base#"$prefix"}
    n=${n#-}
    case "$n" in ''|*[!0-9]*) continue ;; esac
    if [ "$n" -gt "$best" ]; then best=$n; newest="$d"; fi
  done
  [ "$best" -ge 0 ] || return 0
  for d in "$dir/$prefix"*; do
    [ -d "$d" ] || continue
    [ "$d" = "$newest" ] && continue
    base=$(basename "$d"); n=${base#"$prefix"}; n=${n#-}
    case "$n" in ''|*[!0-9]*) continue ;; esac
    mr_zap "$d"
  done
  info "keeping $(basename "$newest")"
}

mr_quit_app() {
  local a="$1"
  pgrep -x "$a" >/dev/null 2>&1 || pgrep -f "/$a.app/" >/dev/null 2>&1 || return 0
  if [ "$MR_GO" = "1" ]; then
    info "quitting $a"
    osascript -e "tell application \"$a\" to quit" >/dev/null 2>&1
    sleep 2
  else
    info "(would quit $a)"
  fi
}

mr_free() {
  df -h /System/Volumes/Data 2>/dev/null | tail -1 \
    || df -h / | tail -1
}

mr_purgeable() {
  diskutil info / 2>/dev/null | grep -i 'Container Free Space' | sed 's/^ *//'
}

mr_require_macos() {
  [ "$(uname -s)" = "Darwin" ] || { err "macreclaim only runs on macOS."; exit 1; }
}

mr_banner() {
  echo "==============================================="
  if [ "$MR_GO" = "1" ]; then
    printf " %sLIVE RUN — files will be deleted%s\n" "$C_R" "$C_0"
  else
    printf " %sDRY RUN — nothing will be deleted%s\n" "$C_G" "$C_0"
  fi
  echo " $(date)"
  echo "==============================================="
}

mr_total() {
  hdr "TOTAL"
  printf "  %s MB  (~%s GB)\n" "$MR_TOTAL_MB" "$(gb "$MR_TOTAL_MB")"
}
