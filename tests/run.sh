#!/bin/bash
# macreclaim test suite — plain bash 3.2, no framework, no dependencies.
#
#   tests/run.sh            run everything
#   tests/run.sh guard      run one test (prefix match on the function name)
#
# Every test gets a fresh fake $HOME in a temp dir. `clean` is always invoked
# with /bin/bash so it runs under the bash macOS ships, not a Homebrew one.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASH=/bin/bash
PASS=0; FAIL=0; CUR=""

# ------------------------------------------------------------- harness
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s: %s\n' "$CUR" "$1"; }
assert_eq() {  # assert_eq EXPECTED ACTUAL LABEL
  [ "$1" = "$2" ] && return 0
  fail "$3: expected [$1] got [$2]"
}
assert_exists()  { [ -e "$1" ] && return 0; fail "expected to exist: $1"; }
assert_missing() { [ ! -e "$1" ] && return 0; fail "expected to be gone: $1"; }
assert_grep()    { grep -q -- "$1" "$2" && return 0; fail "expected /$1/ in $(basename "$2")"; }
assert_nogrep()  { grep -q -- "$1" "$2" || return 0; fail "did not expect /$1/ in $(basename "$2")"; }

# Fresh fake home + a PATH whose brew/node are harmless stubs.
setup() {
  T=$(mktemp -d -t macreclaim-test)
  H="$T/home"; mkdir -p "$H" "$T/bin" "$T/reports"
  printf '#!/bin/sh\nexit 0\n' > "$T/bin/brew"; chmod +x "$T/bin/brew"
  printf '#!/bin/sh\necho v22.0.0\n' > "$T/bin/node"; chmod +x "$T/bin/node"
  OUTLOG="$T/out.txt"
}
teardown() { chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"; }

# run_clean ARGS... -> runs clean with fake HOME, stdout+stderr in $OUTLOG, sets RC
run_clean() {
  ( cd "$T" && HOME="$H" PATH="$T/bin:/usr/bin:/bin" MR_SLEEP=0 MACRECLAIM_OUT="$T/reports" \
      "$BASH" "$ROOT/macreclaim" clean "$@" ) > "$OUTLOG" 2>&1
  RC=$?
}

mkfile() {  # mkfile PATH MB — allocate real blocks so du sees them
  mkdir -p "$(dirname "$1")"
  dd if=/dev/zero of="$1" bs=1048576 count="$2" 2>/dev/null
}

git_repo() {  # git_repo DIR YYYY-MM-DD — repo with one commit on that date
  mkdir -p "$1"; ( cd "$1" && git init -q && git config user.email t@t && git config user.name t \
    && touch f && git add f \
    && GIT_AUTHOR_DATE="$2T12:00:00" GIT_COMMITTER_DATE="$2T12:00:00" git commit -qm init )
}

# ------------------------------------------------------------- tests
test_guard_refuses_dangerous_paths() {
  HOME="$H" . "$ROOT/lib/common.sh"
  for p in "" / "$H" "$H/" /Applications /Users /Library /System /System/Library /usr /etc /var /private /opt \
           "$H/../other" "$H/Library/*" "$H/Caches?" /tmp/x "/Volumes" "/Volumes/Backup"; do
    if HOME="$H" mr_guard "$p"; then fail "guard accepted: [$p]"; fi
  done
}

test_guard_accepts_home_and_applications() {
  HOME="$H" . "$ROOT/lib/common.sh"
  for p in "$H/.npm/_cacache" "$H/Library/Caches/pip" "/Applications/Some Tool.app" "$H/Library/Application Support/X"; do
    if ! HOME="$H" mr_guard "$p"; then fail "guard refused: [$p]"; fi
  done
}

test_dry_run_deletes_nothing() {
  mkfile "$H/.npm/_cacache/blob" 3
  mkfile "$H/Library/Caches/pip/blob" 2
  run_clean --tiers a
  assert_eq 0 "$RC" "exit code"
  assert_exists "$H/.npm/_cacache/blob"
  assert_exists "$H/Library/Caches/pip/blob"
  assert_grep "DRY RUN" "$OUTLOG"
  assert_grep "would rm" "$OUTLOG"
  assert_grep "Nothing was deleted" "$OUTLOG"
  assert_eq "" "$(ls "$T/reports")" "no report written for a dry run"
}

test_go_deletes_tier_a_and_writes_log() {
  mkfile "$H/.npm/_cacache/blob" 3
  mkfile "$H/.npm/keep-me/blob" 1
  run_clean --tiers a --go
  assert_eq 0 "$RC" "exit code"
  assert_missing "$H/.npm/_cacache"
  assert_exists "$H/.npm/keep-me/blob"
  assert_grep "removed" "$OUTLOG"
  log=$(ls "$T/reports"/clean-*.txt 2>/dev/null | head -1)
  [ -n "$log" ] || { fail "no clean log written"; return; }
  assert_grep "^removed" "$log"
  assert_grep "_cacache" "$log"
  assert_grep "^total" "$log"
  assert_nogrep $'\033' "$log"
}

test_unknown_tier_is_an_error() {
  run_clean --tiers a,x
  assert_eq 2 "$RC" "exit code"
  assert_grep "unknown tier" "$OUTLOG"
}

test_failed_removal_sets_exit_code() {
  mkfile "$H/.npm/_cacache/blob" 1
  chmod 555 "$H/.npm"           # rm -rf of _cacache must fail: parent not writable
  run_clean --tiers a --go
  chmod 755 "$H/.npm"
  assert_eq 1 "$RC" "exit code"
  assert_grep "FAILED" "$OUTLOG"
}

test_refused_config_path_sets_exit_code() {
  printf 'MR_EXTRA_TIER_A=("/etc")\n' > "$T/bad.conf"
  run_clean --tiers a --go --config "$T/bad.conf"
  assert_eq 1 "$RC" "exit code"
  assert_grep "REFUSED" "$OUTLOG"
  assert_exists /etc
}

test_tier_c_explicit_paths() {
  mkfile "$H/work/old/node_modules/x/blob" 2
  printf 'MR_NODE_MODULES_PATHS=("$HOME/work/old/node_modules")\n' > "$T/c.conf"
  run_clean --tiers c --go --config "$T/c.conf"
  assert_eq 0 "$RC" "exit code"
  assert_missing "$H/work/old/node_modules"
}

test_tier_c_auto_discovery_respects_staleness_guard_and_total() {
  git_repo "$H/work/old" 2020-01-01
  git_repo "$H/work/new" "$(date +%Y-%m-%d)"
  mkfile "$H/work/old/node_modules/x/blob" 5
  mkfile "$H/work/new/node_modules/x/blob" 2
  mkfile "$H/work/nogit/node_modules/x/blob" 2      # not a repo: never touched
  printf 'MR_NODE_MODULES_ROOTS=("$HOME/work")\nMR_STALE_DAYS=30\n' > "$T/c.conf"

  run_clean --tiers c --config "$T/c.conf"           # dry run first
  assert_eq 0 "$RC" "dry exit code"
  assert_exists "$H/work/old/node_modules"
  assert_grep "would rm.*work/old/node_modules" "$OUTLOG"
  assert_nogrep "work/new/node_modules" "$OUTLOG"
  assert_nogrep "nogit" "$OUTLOG"
  # the auto-discovered 5 MB must be in the total (this used to run in a subshell)
  total=$(sed -n 's/^ *\([0-9][0-9]*\) MB  (~.*/\1/p' "$OUTLOG" | tail -1)
  [ "${total:-0}" -ge 5 ] || fail "total [$total] should include auto-discovered node_modules"

  run_clean --tiers c --go --config "$T/c.conf"
  assert_eq 0 "$RC" "go exit code"
  assert_missing "$H/work/old/node_modules"
  assert_exists "$H/work/new/node_modules/x/blob"
  assert_exists "$H/work/nogit/node_modules/x/blob"
}

test_tier_c_auto_discovery_goes_through_guard() {
  # A root outside $HOME must be refused by the guard, not deleted.
  mkdir -p "$T/outside/repo"; git_repo "$T/outside/repo" 2020-01-01
  mkfile "$T/outside/repo/node_modules/x/blob" 1
  printf 'MR_NODE_MODULES_ROOTS=("%s/outside")\n' "$T" > "$T/c.conf"
  run_clean --tiers c --go --config "$T/c.conf"
  assert_eq 1 "$RC" "exit code"
  assert_grep "REFUSED" "$OUTLOG"
  assert_exists "$T/outside/repo/node_modules/x/blob"
}

test_keep_newest_keeps_highest_revision() {
  mkfile "$H/Library/Caches/ms-playwright/chromium-1100/b" 1
  mkfile "$H/Library/Caches/ms-playwright/chromium-1243/b" 1
  mkfile "$H/Library/Caches/ms-playwright/chromium-999/b" 1
  mkfile "$H/Library/pnpm/store/v3/b" 1
  mkfile "$H/Library/pnpm/store/v10/b" 1
  run_clean --tiers a --go
  assert_exists "$H/Library/Caches/ms-playwright/chromium-1243"
  assert_missing "$H/Library/Caches/ms-playwright/chromium-1100"
  assert_missing "$H/Library/Caches/ms-playwright/chromium-999"
  assert_exists "$H/Library/pnpm/store/v10"
  assert_missing "$H/Library/pnpm/store/v3"
}

test_nvm_keeps_current_and_default() {
  mkdir -p "$H/.nvm/versions/node/v18.0.0" "$H/.nvm/versions/node/v20.5.1" \
           "$H/.nvm/versions/node/v22.0.0" "$H/.nvm/alias"
  echo 20 > "$H/.nvm/alias/default"          # bare major resolves to highest v20.*
  run_clean --tiers b --go
  assert_exists "$H/.nvm/versions/node/v22.0.0"   # current (stub node -v)
  assert_exists "$H/.nvm/versions/node/v20.5.1"   # default alias
  assert_missing "$H/.nvm/versions/node/v18.0.0"
}

test_diff_reports_growth_shrink_new_and_gone() {
  old="$T/old.txt"; new="$T/new.txt"
  cat > "$old" <<EOF
macreclaim scan — old
=========== VOLUMES ===========
Filesystem        Size    Used   Avail Capacity iused ifree %iused  Mounted on
/dev/disk3s5     460Gi   305Gi   100Gi    72%    5.5M  1.3G    0%   /System/Volumes/Data
=========== HOME TOP-LEVEL ===========
 10G	$H/Library
2.0G	$H/.cache
500M	$H/gone-dir
=========== DEV CACHES ===========
1.5G	$H/.cache/uv
=========== node_modules >= 100MB ===========
    300 MB  $H/work/a/node_modules
=========== /Applications (size + last opened, oldest first) ===========
     966 MB  2026-01-01    Chrome.app
EOF
  cat > "$new" <<EOF
macreclaim scan — new
=========== VOLUMES ===========
Filesystem        Size    Used   Avail Capacity iused ifree %iused  Mounted on
/dev/disk3s5     460Gi   270Gi   130Gi    72%    5.5M  1.3G    0%   /System/Volumes/Data
=========== HOME TOP-LEVEL ===========
 14G	$H/Library
1.9G	$H/.cache
800M	$H/new-dir
=========== DEV CACHES ===========
 40M	$H/.cache/uv
=========== node_modules >= 100MB ===========
    300 MB  $H/work/a/node_modules
=========== /Applications (size + last opened, oldest first) ===========
     100 MB  2026-01-01    Chrome.app
EOF
  ( HOME="$H" "$BASH" "$ROOT/macreclaim" diff "$old" "$new" ) > "$OUTLOG" 2>&1
  RC=$?
  assert_eq 0 "$RC" "exit code"
  assert_grep "Avail.*100Gi.*130Gi" "$OUTLOG"
  assert_grep "+4.0 GB.*~/Library" "$OUTLOG"
  assert_grep "\-1.5 GB.*~/.cache/uv" "$OUTLOG"
  assert_grep "gone.*~/gone-dir" "$OUTLOG"
  assert_grep "new.*~/new-dir" "$OUTLOG"
  assert_grep "\-866 MB.*Chrome.app" "$OUTLOG"
  assert_nogrep "work/a/node_modules" "$OUTLOG"     # unchanged
  assert_nogrep "~/.cache " "$OUTLOG"               # 2.0G -> 1.9G is inside du rounding
}

test_diff_needs_two_reports() {
  ( cd "$T" && "$BASH" "$ROOT/macreclaim" diff ) > "$OUTLOG" 2>&1
  RC=$?
  assert_eq 1 "$RC" "exit code with no reports"
}

# ------------------------------------------------------------- runner
filter="${1:-}"
for t in $(declare -F | awk '{print $3}' | grep '^test_' | sort); do
  [ -z "$filter" ] || case "$t" in "test_$filter"*|"$filter"*) ;; *) continue ;; esac
  CUR="$t"; before=$FAIL
  setup
  "$t"
  teardown
  if [ "$FAIL" -eq "$before" ]; then PASS=$((PASS + 1)); printf '  ok   %s\n' "$t"; fi
done
echo
[ "$FAIL" -eq 0 ] && { echo "all $PASS tests passed"; exit 0; }
echo "$PASS passed, $FAIL failed"; exit 1
