# macreclaim

Find and reclaim disk space on macOS. Four small bash scripts, no dependencies, no installer.

```bash
git clone https://github.com/Ariyapong/macreclaim.git
cd macreclaim
./macreclaim scan
```

---

## The thing nobody tells you about APFS

**Deleting files on a Mac often frees no visible space at all.**

Blocks referenced by Time Machine *local snapshots* become **purgeable**, not free. You can delete 800,000 files and watch `df` report the exact same number — or report *less* free space than before, because the snapshots grew to retain everything you just removed.

This is not a bug and it is not your cleanup failing. It is how APFS works.

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

It drops the local snapshots and reports anything still held open by a running process. On a real cleanup this was the difference between **0 GB** and **44 GB** — the deletions had worked perfectly the whole time.

> Local snapshots are macOS's automatic on-disk restore points. Deleting them does **not** touch Time Machine backups on an external or network drive, and macOS recreates them on its own schedule.

---

## Commands

| Command | What it does | Time |
|---|---|---|
| `macreclaim scan` | Read-only full audit → timestamped report | 3–10 min |
| `macreclaim drill` | Expands the biggest directories found by the scan | ~1 min |
| `macreclaim clean` | Tiered cleanup — **dry run unless `--go`** | ~1 min |
| `macreclaim release` | Drops local snapshots so the space appears | ~30 s |

### Typical run

```bash
./macreclaim scan                    # read the report
./macreclaim drill                   # expand whatever looked big

cp macreclaim.conf.example macreclaim.conf
$EDITOR macreclaim.conf              # fill in YOUR machine's paths

./macreclaim clean --tiers a,b       # preview — deletes nothing
./macreclaim clean --tiers a,b --go  # execute
./macreclaim release                 # make the space visible
```

---

## Tiers

| Tier | Contents | Config needed |
|---|---|---|
| **a** | Regenerable caches — npm, pnpm, puppeteer, playwright, pip, yarn, editor caches, Homebrew | No |
| **b** | Rebuildable — NuGet, SonarLint, Gradle, Maven, DerivedData, CocoaPods, old Node versions | No |
| **c** | `node_modules` in stale repos | Yes |
| **d** | Apps and their leftovers | **Yes — empty by default** |
| **e** | Electron caches that require re-login | **Yes — empty by default** |

Tiers **d** and **e** ship empty on purpose. A cleanup script that arrives with somebody else's delete list is a footgun.

Tier **a** is smart about versioned caches: it keeps the newest playwright browser revision and the newest pnpm store, removing only superseded ones. Tier **b** always keeps your current Node version and your nvm `default` alias.

---

## Safety

- **Dry run is the default.** Nothing is deleted without `--go`.
- **Hard rails.** Every path passes a guard that refuses `/`, `$HOME`, `/Applications`, `/Library`, `/System`, `/usr`, `/etc`, `/var`, anything containing `..` or an unexpanded glob, and anything outside `$HOME` or `/Applications`.
- **Explicit paths only.** No wildcards into `rm`, no `find -delete`.
- **`scan`, `drill` and `release` never delete your files.** Only `clean --go` does.
- Every removal prints its path and size, with a running total.

### Things this will never touch

Mail stores, Messages, Photos libraries, iOS device backups, and messaging-app group containers (Outlook, LINE, WhatsApp, Signal). These are multi-gigabyte and irreplaceable. They are **data**, not cache. The config template lists them under a "never add these" heading.

### Spotlight's "last opened" date lies

`mdls -name kMDItemLastUsedDate` returns `null` for plenty of apps that are used daily — during one audit it reported Chrome as never-opened while Chrome sat on 966 MB of profile data. `scan` prints the dates because they're a useful *hint*, and labels them accordingly. Treat them as candidates to confirm, never as proof.

---

## Re-running it later

`scan`, `drill` and `release` are generic — run them any time.

**`macreclaim.conf` is not.** It encodes which repos were cold, which Node versions mattered, and which apps existed *on the day you wrote it*. Re-scan and revise it before each cleanup. Don't run `--go` from a months-old config, and don't copy someone else's.

---

## Requirements

macOS. Bash 3.2 (what macOS ships) — no Homebrew bash needed. `sudo` only for `release`, only for `tmutil`.

## Contributing

Issues and PRs welcome. Two rules: dry-run stays the default, and nothing machine-specific goes in the committed config.

## License

MIT — see [LICENSE](LICENSE).
