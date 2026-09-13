#!/usr/bin/env bash
# macreclaim clean — tiered cleanup. DRY RUN unless --go is passed.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$DIR/lib/common.sh"
mr_require_macos

H="$HOME"

# ---- defaults (a config file may override any of these) --------------------
MR_TIERS="a"
MR_CONFIG=""
MR_NVM_KEEP=()
MR_NODE_MODULES_PATHS=()
MR_NODE_MODULES_ROOTS=()
MR_STALE_DAYS=30
MR_APP_PATHS=()
MR_ELECTRON_PARTITIONS=()
MR_EXTRA_TIER_A=()
MR_EXTRA_TIER_B=()
MR_QUIT_APPS=()

usage() {
  cat <<'EOF'
macreclaim clean [options]

  --tiers a,b,c,d,e   which tiers to run (default: a)
  --config FILE       machine-specific config (default: ./macreclaim.conf)
  --go                actually delete; without it, nothing is removed
  -h, --help          this

Tiers
  a  Regenerable caches. Safe on any Mac — these refill automatically.
  b  Rebuildable caches. Safe, but re-downloads on your next build.
  c  node_modules in stale repos. Restored with one install command.
  d  Apps and their leftovers.        (config only — nothing built in)
  e  Electron caches needing re-login.(config only — nothing built in)

Tiers d and e are deliberately empty until YOU list paths in the config.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --tiers)  MR_TIERS="$2"; shift 2 ;;
    --tiers=*) MR_TIERS="${1#*=}"; shift ;;
    --config) MR_CONFIG="$2"; shift 2 ;;
    --config=*) MR_CONFIG="${1#*=}"; shift ;;
    --go)     MR_GO=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "unknown option: $1"; usage; exit 2 ;;
  esac
done

[ -n "$MR_CONFIG" ] || { [ -f "./macreclaim.conf" ] && MR_CONFIG="./macreclaim.conf"; }
if [ -n "$MR_CONFIG" ]; then
  [ -f "$MR_CONFIG" ] || { err "config not found: $MR_CONFIG"; exit 1; }
  # shellcheck disable=SC1090
  . "$MR_CONFIG"
fi

has_tier() { case ",$MR_TIERS," in *",$1,"*) return 0 ;; esac; return 1; }

mr_banner
[ -n "$MR_CONFIG" ] && info "config: $MR_CONFIG" || info "config: none (built-in defaults)"
info "tiers:  $MR_TIERS"
echo
echo "BEFORE:"; mr_free

if [ "$MR_GO" = "1" ] && [ "${#MR_QUIT_APPS[@]}" -gt 0 ]; then
  hdr "QUITTING APPS"
  for a in "${MR_QUIT_APPS[@]}"; do mr_quit_app "$a"; done
fi

# ============================================================ TIER A
if has_tier a; then
  hdr "TIER A — regenerable caches"

  mr_zap "$H/.npm/_cacache"
  mr_zap "$H/.npm/_npx"
  mr_zap "$H/.cache/puppeteer"
  mr_zap "$H/Library/Caches/Yarn"
  mr_zap "$H/.yarn/berry/cache"
  mr_zap "$H/Library/Caches/pip"
  mr_zap "$H/.cache/pip"
  mr_zap "$H/.cache/uv"                  # uv's download/archive cache; venvs keep their own copies
  mr_zap "$H/Library/Caches/electron"
  mr_zap "$H/Library/Caches/typescript"
  mr_zap "$H/Library/Application Support/Google/GoogleUpdater/crx_cache"

  info "--- pnpm store: keeping only the newest version ---"
  for s in "$H/Library/pnpm/store" "$H/.pnpm-store"; do
    mr_keep_newest "$s" "v"
  done

  info "--- playwright: keeping the newest revision of each browser ---"
  PW="$H/Library/Caches/ms-playwright"
  for b in chromium chromium_headless_shell firefox webkit; do
    mr_keep_newest "$PW" "$b"
  done

  info "--- app updater staging caches (*.ShipIt) ---"
  for d in "$H/Library/Caches/"*.ShipIt; do
    [ -d "$d" ] && mr_zap "$d"
  done

  info "--- editor caches (data and settings untouched) ---"
  for v in "Code" "Code - Insiders" "VSCodium" "Cursor" "Windsurf"; do
    base="$H/Library/Application Support/$v"
    [ -d "$base" ] || continue
    mr_zap "$base/CachedExtensionVSIXs"
    mr_zap "$base/CachedData"
    mr_zap "$base/Crashpad"
    mr_zap "$base/logs"
  done

  if [ "${#MR_EXTRA_TIER_A[@]}" -gt 0 ]; then
    info "--- from config ---"
    for p in "${MR_EXTRA_TIER_A[@]}"; do mr_zap "$p"; done
  fi

  info "--- homebrew ---"
  if command -v brew >/dev/null 2>&1; then
    if [ "$MR_GO" = "1" ]; then
      bout=$(brew cleanup -s 2>/dev/null | tail -3)
    else
      bout=$(brew cleanup -n 2>/dev/null | tail -1)
    fi
    if [ -n "$bout" ]; then echo "$bout" | sed 's/^/  /'
    else info "nothing for brew to clean"; fi
  else
    info "brew not installed, skipping"
  fi
fi

# ============================================================ TIER B
if has_tier b; then
  hdr "TIER B — rebuildable (re-downloads on next build)"

  mr_zap "$H/.nuget/packages"
  mr_zap "$H/.sonar/cache"
  mr_zap "$H/.sonarlint/storage"
  mr_zap "$H/.sonarlint/work"
  mr_zap "$H/Library/Caches/CocoaPods"
  mr_zap "$H/Library/Developer/Xcode/DerivedData"
  mr_zap "$H/.gradle/caches"
  mr_zap "$H/.m2/repository"
  mr_zap "$H/.cargo/registry/cache"

  info "--- nvm: keeping current, default, and anything in MR_NVM_KEEP ---"
  NVD="$H/.nvm/versions/node"
  if [ -d "$NVD" ]; then
    KEEP=""
    keep_add() { case " $KEEP " in *" $1 "*) return ;; esac; KEEP="$KEEP $1"; }
    cur=$(node -v 2>/dev/null); [ -n "$cur" ] && keep_add "$cur"
    alias_default=$(cat "$H/.nvm/alias/default" 2>/dev/null)
    if [ -n "$alias_default" ]; then
      # resolve a bare major like "22" to the highest installed v22.*
      res=$(ls "$NVD" 2>/dev/null | grep "^v${alias_default#v}" | sed 's/^v//' \
            | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
      [ -n "$res" ] && keep_add "v$res"
    fi
    if [ "${#MR_NVM_KEEP[@]}" -gt 0 ]; then
      for k in "${MR_NVM_KEEP[@]}"; do keep_add "$k"; done
    fi
    info "keeping:$KEEP"
    for v in "$NVD"/*; do
      [ -d "$v" ] || continue
      name=$(basename "$v")
      case " $KEEP " in *" $name "*) continue ;; esac
      mr_zap "$v"
    done
  else
    info "nvm not installed, skipping"
  fi

  if [ "${#MR_EXTRA_TIER_B[@]}" -gt 0 ]; then
    info "--- from config ---"
    for p in "${MR_EXTRA_TIER_B[@]}"; do mr_zap "$p"; done
  fi
fi

# ============================================================ TIER C
if has_tier c; then
  hdr "TIER C — node_modules in stale repos"
  info "restore with: npm i   (or pnpm/yarn install)"

  if [ "${#MR_NODE_MODULES_PATHS[@]}" -gt 0 ]; then
    for p in "${MR_NODE_MODULES_PATHS[@]}"; do mr_zap "$p"; done
  fi

  if [ "${#MR_NODE_MODULES_ROOTS[@]}" -gt 0 ]; then
    cutoff=$(date -v-"${MR_STALE_DAYS}"d +%Y-%m-%d 2>/dev/null)
    info "--- auto-discovery: no commit since $cutoff (${MR_STALE_DAYS} days) ---"
    for root in "${MR_NODE_MODULES_ROOTS[@]}"; do
      [ -d "$root" ] || continue
      # Process substitution keeps this loop in the main shell, so mr_zap's
      # guard, total and failure count all apply (bash 3.2 supports it).
      while read -r nm; do
        repo=$(dirname "$nm")
        [ -d "$repo/.git" ] || continue
        last=$(git -C "$repo" log -1 --format=%cd --date=short 2>/dev/null)
        [ -n "$last" ] || continue
        if [ "$last" \< "$cutoff" ]; then
          info "last commit $last: $(tilde "$repo")"
          mr_zap "$nm"
        fi
      done < <(find "$root" -maxdepth 4 -type d -name node_modules -prune 2>/dev/null)
    done
  fi
fi

# ============================================================ TIER D
if has_tier d; then
  hdr "TIER D — apps and leftovers (config only)"
  if [ "${#MR_APP_PATHS[@]}" -eq 0 ]; then
    info "nothing configured — add paths to MR_APP_PATHS in your config"
  else
    for p in "${MR_APP_PATHS[@]}"; do mr_zap "$p"; done
  fi
fi

# ============================================================ TIER E
if has_tier e; then
  hdr "TIER E — Electron caches (you will likely need to sign in again)"
  if [ "${#MR_ELECTRON_PARTITIONS[@]}" -eq 0 ]; then
    info "nothing configured — add paths to MR_ELECTRON_PARTITIONS in your config"
  else
    for p in "${MR_ELECTRON_PARTITIONS[@]}"; do mr_zap "$p"; done
  fi
fi

# ============================================================ WRAP
mr_total

if [ "$MR_GO" = "1" ]; then
  hdr "AFTER"
  sleep 3
  mr_free
  echo
  if tmutil listlocalsnapshots / 2>/dev/null | grep -q "com.apple.TimeMachine"; then
    warn "df may show little or no change above — that is expected."
    warn "Time Machine local snapshots are still holding the freed blocks."
    warn "Run:  macreclaim release"
  else
    ok "No local snapshots on this volume — the space above is already free."
    info "Time Machine creates those snapshots. Without it, deletions free space"
    info "immediately and 'macreclaim release' has nothing to do."
  fi
else
  echo
  ok "Nothing was deleted. Re-run with --go to execute."
fi
