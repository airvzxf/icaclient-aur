# Testing protocol

The point of this document is to make "it works" mean something specific. Without a protocol, "it works" is just an opinion. With one, it is a reproducible result.

## Scenarios

Each row is a distinct scenario. For each, you should be able to answer yes/no with **concrete evidence** (terminal output, log line, screenshot).

| ID | Scenario | How to test | Expected outcome (if the package works) |
|---|---|---|---|
| **S1** | `selfservice` launches | `/opt/Citrix/ICAClient/selfservice &` | GUI window appears; no `libwebkit2gtk-4.0.so.37: cannot open shared object file`; no `libsoup-2.4.so.1: cannot open shared object file` |
| **S2** | `wfica` opens a `.ica` file from a browser download | double-click a `.ica` file, or `wfica ~/Downloads/xxx.ica` | session opens; no error in terminal |
| **S3** | `wfica` "Connecting..." dialog renders | same as S2, watch for the dialog box | the dialog shows (not just a hang on "Connecting...") |
| **S4** | Install works on a system **without** `webkit2gtk` (AUR) installed | `pacman -Rdd webkit2gtk` (carefully), then `makepkg -si` and `pacman -U` the result | install succeeds; S1, S2, S3 all pass |
| **S5** | Build time | `time makepkg -sf` | target: <5 min, ceiling: <15 min |
| **S6** | Real Citrix session connects (not just binary launch) | actually launch a session through `selfservice` or `wfica .ica` | session connects to your Citrix farm, GUI appears, no crash in `journalctl --user -xe` for the past 5 min |
| **S7** | No spurious new system dependencies | compare `pacman -Qe` before and after install | difference = exactly the new icaclient entry, nothing else (unless `webkit2gtk` was the only thing removed, in which case its absence is expected) |

## How to report

Open a GitHub issue titled:

```
Test report: <YYYY-MM-DD> - <distro-version> - <S-IDs>
```

Use this template:

```markdown
**System**
- Distro / version: (e.g., Arch Linux, 2026.06.01 installer)
- Kernel: (`uname -r`)
- AUR helper: (yay / paru / makepkg directly)
- Existing webkit2gtk packages: (`pacman -Q | grep -i webkit`)
- Existing libsoup packages: (`pacman -Q | grep -i soup`)
- Display server: (X11 / Wayland / Wayland+XWayland)

**PKGBUILD variant tested**
- Source: (commit SHA of this repo, or `pkgbuilds/<file>.PKGBUILD`, or "upstream AUR pkgrel=N")
- Diff vs upstream: (`git diff <upstream> -- PKGBUILD`, attached or pasted)

**Results**
| Scenario | Result | Evidence |
|---|---|---|
| S1 | ✅ / ❌ / ⏭️ skipped | paste of relevant output |
| S2 | ✅ / ❌ / ⏭️ skipped | ... |
| S3 | ✅ / ❌ / ⏭️ skipped | ... |
| S4 | ✅ / ❌ / ⏭️ skipped | ... |
| S5 | ✅ / ❌ (time) | ... |
| S6 | ✅ / ❌ / ⏭️ skipped (no farm) | ... |
| S7 | ✅ / ❌ | list of new packages, or "none" |

**Observations**
- (anything weird, even if everything passes; e.g., "selfservice shows the window but the URL bar is blank for 5 seconds, then loads")

**Caveats**
- (anything you didn't test; e.g., "I don't have a real Citrix farm, only ran ldd")
```

## Current test matrix

The reusable test matrix template lives in [`docs/test-matrix-template.md`](docs/test-matrix-template.md). When a candidate PKGBUILD variant exists, open an issue titled `Test matrix: <variant-name>` with that template filled in. Testers then add a row to each table for the scenarios they run, linking to their individual test report issue (filed from [`.github/ISSUE_TEMPLATE/test-report.md`](.github/ISSUE_TEMPLATE/test-report.md)).

## What NOT to test (and why)

These are known-broken or known-illusion-of-working approaches. Do not propose them as solutions; do not be misled by reports of "it works" using them.

### ❌ `webkit2gtk-4.1` as a direct replacement for `webkit2gtk`

Multiple commenters (codemonkey777, mag37, Drake) suggested this. buzo tested on 2026-06-10 and got:

```
libsoup-ERROR **: HH:MM:SS: libsoup2 symbols detected. Using libsoup2 and libsoup3 in the same process is not supported.
```

This is an ABI conflict at the C level, not a configuration issue. The Citrix binaries were compiled against libsoup-2.4 and cannot link against libsoup-3.0.

**Caveat:** it can *appear* to work for users who only run `wfica` on .ica files, because `wfica` does not have webkit in its direct NEEDED list — it loads `UIDialogLibWebKit3.so` at runtime only when a dialog needs to be shown. If the connection succeeds silently, webkit is never loaded, no error appears. This is not a fix.

### ❌ Symlink hacks (`4.0 → 4.1`)

```
ln -s /usr/lib/libwebkit2gtk-4.1.so.0 /usr/lib/libwebkit2gtk-4.0.so.37
ln -s /usr/lib/libjavascriptcoregtk-4.1.so.0 /usr/lib/libjavascriptcoregtk-4.0.so.18
```

Same as above. Works for `wfica`+`.ica` from a browser download (because that path doesn't load webkit). Crashes for `selfservice` (which loads webkit immediately).

### ❌ `pacman -S webkit2gtk-4.1` + `yay --assume-installed webkit2gtk`

yrf's suggestion from 2026-05-05. Same outcome as the symlink hack.

## What we DO want to test

Once a candidate PKGBUILD exists under `pkgbuilds/`, the protocol is:
1. Pick the variant.
2. Run scenarios S1-S7 on a machine that is reasonably representative of "an Arch user trying to use Citrix for work".
3. Report using the template above.

The minimum useful report covers S1, S2, S4. The full report covers all 7.

## Local checklist for testers

Before opening the issue, make sure you have:

- [ ] `journalctl --user -xe | grep -i citrix` and `journalctl -xe | grep -i citrix` available for the past 5 min of activity
- [ ] The output of `readelf -d /opt/Citrix/ICAClient/selfservice | grep -E "RUNPATH|RPATH|NEEDED"`
- [ ] The output of `ldd /opt/Citrix/ICAClient/selfservice | grep -iE "not found|webkit|soup"`
- [ ] The output of `pacman -Q | grep -iE "webkit|soup|patchelf"`
- [ ] The output of `time makepkg -sf 2>&1 | tail -30`

These five outputs are enough to diagnose almost any failure.

## Infrastructure

The S1-S7 scenarios above are the **what** to test. The **how** (the tooling that makes "I tested it" reproducible) lives in [`docs/testing-infrastructure.md`](docs/testing-infrastructure.md). Read that document for:

- The 5-layer testing model (L0 `namcap` → L4 QEMU/KVM)
- `makechrootpkg` for clean builds (L2) — what the Arch build server uses
- Three options for GUI smoke testing (L3): Distrobox, `systemd-nspawn`, and Podman
- X11 and Wayland display forwarding
- PulseAudio and PipeWire audio forwarding
- D-Bus and GPU passthrough
- sudo setup (passwordless vs interactive)

Quick start (assuming `bundle-4.0-icu70` is the variant under `pkgbuilds/`):

```bash
# L0: lint
namcap pkgbuilds/bundle-4.0-icu70/PKGBUILD

# L2: clean build (chroot at ~/.local/chroots/arch-citrix)
makechrootpkg -c -r ~/.local/chroots/arch-citrix

# L3: GUI smoke test (easiest: Distrobox)
distrobox create --image archlinux:latest --name citrix-test
distrobox enter citrix-test
# then: makepkg -si and /opt/Citrix/ICAClient/selfservice
```

The infrastructure is a **means** to generate the checklist outputs in the test report; the S1-S7 scenarios still require human validation (eyes on a GUI, a real Citrix farm for S6).
