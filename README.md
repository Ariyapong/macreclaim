# macreclaim

**You delete 40 GB. `df` says you freed nothing.**

That's not your cleanup failing — it's APFS. Blocks still referenced by Time Machine *local snapshots* become **purgeable**, not free, so the space stays invisible until those snapshots are dropped. Most cleanup tools delete and walk away, leaving you to wonder what happened.

**This only happens when Time Machine is enabled.** With it off, deletions free space immediately, and your problem is the other one: knowing what is safe to delete in the first place. macreclaim checks which case you're in and tells you, instead of assuming.

macreclaim audits what's actually eating your disk, deletes only what you approve, then **releases what APFS is holding back**. On a real cleanup that last step was the difference between `0 GB` and `44 GB`.

```bash
git clone https://github.com/Ariyapong/macreclaim.git
cd macreclaim
./macreclaim scan
```

Five bash scripts. No dependencies, no installer, no Homebrew. macOS · bash 3.2 · MIT.

---

## Why your cleanup freed nothing

How to tell your deletion actually worked:

```bash
df -h /System/Volumes/Data
```

- **`iused` went down** → the files are gone. The space is just held.
- **`Avail` didn't move** → snapshots are holding it.

And these two commands will disagree, sometimes by tens of gigabytes:

| Command | Counts purgeable? |
|---|---|
| `df -h` → **Avail** | No |
| `diskutil info /` → **Container Free Space** | Yes |

`macreclaim release` resolves it:

```bash
./macreclaim release
```

It drops the local snapshots and reports anything still held open by a running process — one line per file, with `(xN)` when several processes or descriptors hold the same one.

If there are no snapshots, it says so and exits — nothing to do, and your space was already free.

### Why the total is an upper bound

`du` reports a hardlinked store at full size, but blocks are only released once **every** link is gone. pnpm hardlinks its store into each project's `node_modules` (uv does the same from `~/.cache/uv` into virtualenvs), so deleting a store that your projects still reference frees less than the number shown. On one real run the tool reported 39.3 GB and the disk moved 36 GB — the difference was live pnpm hardlinks. Treat the total as a ceiling, not a promise.

> Local snapshots are macOS's automatic on-disk restore points. Deleting them does **not** touch Time Machine backups on an external or network drive, and macOS recreates them on its own schedule.

---

## Commands

| Command | What it does | Time |
|---|---|---|
| `macreclaim scan` | Read-only full audit → timestamped report | 3–10 min |
| `macreclaim drill` | Expands the biggest directories found by the scan | ~1 min |
| `macreclaim clean` | Tiered cleanup — **dry run unless `--go`** | ~1 min |
| `macreclaim release` | Drops local snapshots so the space appears | ~30 s |
| `macreclaim diff` | What changed between two scan reports | instant |

### Options

```bash
macreclaim clean --tiers a,b,c --config FILE --go   # default config: ./macreclaim.conf
macreclaim release --yes                            # skip the "delete snapshots?" prompt
macreclaim diff --min 500 [OLD NEW]                 # only changes of 500 MB or more
macreclaim drill ~/some/dir                         # add directories to the drill

MACRECLAIM_OUT=~/scans macreclaim scan              # reports go to ./reports by default
MR_BIG_FILE_MB=500 MR_NODE_MODULES_MB=250 MR_REPO_MB=1000 macreclaim scan   # scan thresholds
```

### Reading the scan report

- While it runs, the terminal shows one timestamped line per section so you can see which part is slow. The report itself only lands when the scan finishes.
- Sizes are **allocated blocks**, not nominal size. A sparse disk image such as Docker's `Docker.raw` or a VM's `rootfs.img` shows what it really occupies (22 GB, say), not the 60 GB it claims in Finder.
- If a section ends with `(find reported N unreadable entries; first: …)`, part of your home folder was skipped. The usual cause is Terminal without **Full Disk Access** (System Settings → Privacy & Security); grant it and re-run. Without that line, the walk was complete.
- Reports are plain text with no colour codes, so they diff cleanly between runs. `macreclaim diff` does that for you: it compares the two newest reports (or any two you name) and lists what grew, shrank, appeared or vanished, sorted by size. Changes inside the rounding of `du -h` are suppressed, so `130G` becoming `129G` is not reported as a 1 GB change.

### Typical run

```bash
./macreclaim scan                    # read the report
./macreclaim drill                   # expand whatever looked big

cp macreclaim.conf.example macreclaim.conf
$EDITOR macreclaim.conf              # fill in YOUR machine's paths

./macreclaim clean --tiers a,b       # preview — deletes nothing
./macreclaim clean --tiers a,b --go  # execute
./macreclaim release                 # make the space visible

./macreclaim scan && ./macreclaim diff   # later: what changed since last time?
```

---

## Tiers

| Tier | Contents | Config needed |
|---|---|---|
| **a** | Regenerable caches — npm, pnpm, uv, puppeteer, playwright, pip, yarn, editor caches, Homebrew | No |
| **b** | Rebuildable — NuGet, SonarLint, Gradle, Maven, DerivedData, CocoaPods, old Node versions | No |
| **c** | `node_modules` in stale repos | Yes |
| **d** | Apps and their leftovers | **Yes — empty by default** |
| **e** | Electron caches that require re-login | **Yes — empty by default** |

Tiers **d** and **e** ship empty on purpose. A cleanup script that arrives with somebody else's delete list is a footgun.

Tier **a** is smart about versioned caches: it keeps the newest playwright browser revision and the newest pnpm store, removing only superseded ones. Tier **b** always keeps your current Node version and your nvm `default` alias.

---

## Safety

- **Dry run is the default.** Nothing is deleted without `--go`.
- **Hard rails.** Every path passes a guard that refuses `/`, `$HOME`, `/Applications`, `/Library`, `/System`, `/usr`, `/etc`, `/var`, anything containing `..` or an unexpanded glob, and anything outside `$HOME` or `/Applications`. It also refuses Mail, Messages, iOS device backups and any `.photoslibrary`, even from your own config.
- **Explicit paths only.** No wildcards into `rm`, no `find -delete`.
- **`scan`, `drill`, `diff` and `release` never delete your files.** Only `clean --go` does.
- Every removal prints its path and size, with a running total.
- **`clean --go` keeps a record.** Every removed, failed or refused path is appended to `reports/clean-<timestamp>.txt`, so "what did I delete last month" has an answer.
- **Exit codes mean something.** `clean` exits 1 if any removal failed or was refused by the guard, and 2 on a bad option or unknown tier. Scripts and agents driving it can rely on that.

### Things this will never touch

Mail stores, Messages, Photos libraries and iOS device backups are refused by the path guard outright. A typo in your config cannot reach them.

Messaging-app group containers (Outlook, LINE, WhatsApp, Signal) are not guarded, because a group container for an app you have uninstalled is a legitimate Tier d target. They are multi-gigabyte and irreplaceable while the app is in use, so the config template lists them under a "never add these" heading. Check what one holds before you add it.

### Spotlight's "last opened" date lies

`mdls -name kMDItemLastUsedDate` returns `null` for plenty of apps that are used daily — during one audit it reported Chrome as never-opened while Chrome sat on 966 MB of profile data. `scan` prints the dates because they're a useful *hint*, and labels them accordingly. Treat them as candidates to confirm, never as proof.

---

## Re-running it later

`scan`, `drill`, `diff` and `release` are generic — run them any time. Scan again, then `macreclaim diff` to see what grew back.

### Driving it from an AI agent

macreclaim was shaped by being run from an agent session, and several choices exist for that reason: reports are plain text with no colour codes, `clean` is a dry run unless told otherwise, exit codes distinguish "refused" from "done", and every live run leaves a log in `reports/`. A workable loop is: `scan`, read the report, propose config entries with a reason for each, dry-run, get a human yes, `--go`, `release`. The human yes is not optional. The guard catches typos, not bad judgement.

**`macreclaim.conf` is not.** It encodes which repos were cold, which Node versions mattered, and which apps existed *on the day you wrote it*. Re-scan and revise it before each cleanup. Don't run `--go` from a months-old config, and don't copy someone else's.

---

## Requirements

macOS. Bash 3.2 (what macOS ships) — no Homebrew bash needed. `git` (from the Xcode command line tools) for the git-repos section of `scan` and for Tier c. `sudo` only in `release`, for `tmutil` and for `lsof` (to see files held open by other users' processes). `scan` needs Terminal to have Full Disk Access to size `~/Library/Mail`, Messages and Group Containers; without it those sections come out small and the report says so.

## Contributing

Issues and PRs welcome. Two rules: dry-run stays the default, and nothing machine-specific goes in the committed config.

```bash
/bin/bash tests/run.sh      # plain-bash test suite, runs against a throwaway fake $HOME
brew install shellcheck     # the one dev tool; not needed to run macreclaim
shellcheck -S warning macreclaim lib/common.sh scripts/*.sh tests/run.sh
```

CI runs both on a macOS runner, under the bash 3.2 that ships with macOS. The tests cover the path guard, dry-run versus `--go`, every tier's keep/remove logic, exit codes and `diff`.

## License

MIT — see [LICENSE](LICENSE).
