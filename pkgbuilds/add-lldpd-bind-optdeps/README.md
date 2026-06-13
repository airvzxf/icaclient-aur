# add-lldpd-bind-optdeps

**Status:** proposed
**Based on:** upstream AUR PKGBUILD @ pkgrel=3 (icaclient 26.01.0.150-3)
**CHANGELOG entry:** [../../CHANGELOG.md](../../CHANGELOG.md) — "2026-06-12 — Variant `add-lldpd-bind-optdeps`: add `lldpd` and `bind` to optdepends"

## What this changes vs upstream

Two additional entries in the `optdepends=()` array of the upstream `pkgbuilds/latest/PKGBUILD`. Nothing else changes — the `package()` function, `depends=()`, `makedepends=()`, `source=()`, `sha256sums=()`, `pkgver`, `pkgrel`, and all 9 support files are byte-identical to upstream.

```diff
 optdepends=('webkit2gtk: provides libwebkit2gtk-4.0 ABI; required for selfservice and the wfica connection dialog'
             'libsoup: provides libsoup-2.4 ABI; required for selfservice and the wfica connection dialog'
+            'lldpd: provides lldpcli (LLDP daemon) for Citrix HDX e911 location services with Microsoft Teams optimized (remedies "lldpcli: command not found" in logs)'
+            'bind: provides DNS utilities for first-launch selfservice StoreFront authentication (remedies "network error" on first launch of selfservice)')
```

## Why

Two environment-specific failure modes have been reported multiple times on the AUR thread. Both are real bugs, both have a simple optdep fix, and neither is universal (they don't affect every Arch user) — which is why `optdepends=` is the right category, not `depends=`.

1. **`lldpd` for HDX / Microsoft Teams e911 location services.**
   - Reported by capadocia on 2025-09-22: "Hi from log output, I can see Citrix is looking for 'lldpd' package. 'citrix-wfica.desktop[33250]: sh: line 1: lldpcli: command not found'."
   - Reiterated by bstrdsmkr on 2026-06-11: "an LLDP implementation is needed for e911 location services when using the Citrix optimized Microsoft teams."
   - The `lldpcli: command not found` error comes from a Citrix script that tries to call the LLDP daemon's CLI to get switch/router location info for the e911 service in the optimized Microsoft Teams client over Citrix HDX.
   - **Verified locally on 26.01.0.150-3:** the lldpcli call is no longer present in the installed Citrix binaries (`HdxRtcEngine`, `wfica`, `selfservice`, `hdxcheck.sh` — all return 0 occurrences of "lldp" via `strings`). So for the current version, the optdep is a no-op. It remains useful for users who downgrade to 25.05.x or 25.08.x, where the call is still there.
   - **`lldpd` is in `[extra]`** (1.0.22-1 at the time of this doc; ~820 KiB installed). `ladvd` is AUR-only, so `lldpd` is the right choice.

2. **`bind` for first-launch selfservice StoreFront DNS resolution.**
   - Reported by ironhak on 2026-06-12 03:53: "when you first launch icaclient you get basket to put your company email, if bind is not installed you would get something like network error and you could only use icaclient only I you have a .Ica file without being able to access the Citrix Workspace portal."
   - Reiterated on 2026-06-11 07:58 and 2026-06-11 08:28.
   - The exact DNS resolution path that fails is environment-specific (ironhak's BBS thread [https://bbs.archlinux.org/viewtopic.php?id=312653](https://bbs.archlinux.org/viewtopic.php?id=312653) shows Manjaro and Suse users hit it; not every Arch user does). The `.ica` file workflow is unaffected.
   - **Verified locally on 26.01.0.150-3 (this dev host has `bind 9.20.23-1` installed):** static analysis of the Citrix code finds no NEEDED bind libs (`libbind.so`, `libisc.so`, `libdns.so` — all absent from `readelf -d` of `selfservice`, `wfica`, and `UIDialogLibWebKit3.so`) and no shell-script invocations of `dig`/`host`/`nslookup`/`named`. So `bind` is not a hard dep; it's a soft workaround for a glibc-resolver issue that affects some setups. The dev host cannot reproduce the failure mode (no real StoreFront available for testing), so the recommendation is based on ironhak's empirical evidence: "installing `bind` fixes the network error on first launch".
   - **Why `bind` and not `bind-tools`?** ironhak specifically tested `bind` (not `bind-tools`) and it worked. On Arch, `bind` is a superset of `bind-tools` (it `Provides` `bind-tools` and `dnsutils`; `Conflicts` with `bind-tools`). So specifying `bind` covers both. If a tester reports that `bind-tools` (smaller, no DNS server) is sufficient, we can switch in a follow-up.

## Tradeoffs

| Pros | Cons |
|---|---|
| Smallest possible change to upstream (2 lines) | Adds two more optdep messages — the optdepends list grows |
| No new build or runtime deps (both are pure optdepends) | `bind` is a 7 MB DNS server; users who install it for icaclient are getting more than they need |
| No new install logic (the existing `package()` is unchanged) | The `lldpd` optdep is a no-op for 26.01.0.150-3 (verified locally) — it only helps users on older versions |
| Both packages are in `[extra]`, no AUR pollution | |
| No functional change for users who don't install `lldpd`/`bind` | |
| Addresses two long-standing AUR threads (2025-09-22, 2026-06-12) | |

## How to test

This is an optdepends-only change. The full S1-S7 test matrix is **overkill**. The minimum useful verification:

- **L0 (namcap):** must pass (no E: errors). The change is a 2-line optdepends addition; namcap's relevant rule is "every optdep should be a real package name".
  ```bash
  namcap pkgbuilds/add-lldpd-bind-optdeps/PKGBUILD
  ```

- **L2 (clean chroot build):** must succeed and produce a `.pkg.tar.zst` identical to upstream except for the two optdepends lines.
  ```bash
  scripts/test-variant.bash add-lldpd-bind-optdeps
  ```
  Expected: `~30-37s build, namcap OK (warnings only), chroot install successful, readelf/ldd outputs identical to latest/`.

- **Visual diff review:** confirm the only differences vs `pkgbuilds/latest/PKGBUILD` are the two optdepends lines.
  ```bash
  diff pkgbuilds/latest/PKGBUILD pkgbuilds/add-lldpd-bind-optdeps/PKGBUILD
  ```

- **S7 (no spurious new deps, host-side):** after `pacman -U` of the built package, `pacman -Qe` should differ from the pre-install state by exactly the new `icaclient` entry. `lldpd` and `bind` only appear if the tester explicitly installs them.

**Optional** (for testers with a real Citrix StoreFront):
- Install `lldpd`, restart any active ICA session, check the Citrix logs for absence of `lldpcli: command not found`.
- Install `bind`, launch `selfservice` against the StoreFront, confirm the "network error" on first launch is gone.

These optional checks are the only way to validate the optdep messages empirically; the L0 + L2 + diff review above is the bar for sending to buzo.

## Known gaps

- **The dev host cannot reproduce ironhak's `bind` symptom** (no real StoreFront). The recommendation of `bind` over `bind-tools` is based on ironhak's AUR report, not local verification.
- **The dev host's installed `26.01.0.150-3` does not contain the `lldpcli` call** in any binary or script (verified via `strings` over `HdxRtcEngine`, `wfica`, `selfservice`, `hdxcheck.sh`, `workspacecheck.sh`, `wfica.sh`, `wfica_assoc.sh` — 0 matches each). The optdep helps users on older Citrix Workspace versions (≤25.08.x) but is a no-op for 26.01.0.150. If Citrix ever reintroduces the call, the optdep becomes load-bearing again.
- **No real Citrix session test (S6) was run.** The host doesn't have a StoreFront account.
- **No aarch64 testing.** The variant's `package()` is identical to upstream, which already supports aarch64, so the variant inherits that. The Citrix source URL regex is unchanged.

## Files in this directory

All 9 support files are byte-identical copies from `pkgbuilds/latest/`:

- `citrix-client.install` — pacman install hook
- `citrix-configmgr.desktop` — `citrix-configmgr` launcher
- `citrix-conncenter.desktop` — `citrix-conncenter` launcher
- `citrix-wfica.desktop` — `wfica` launcher (the one capadocia's lldpcli log line came from)
- `citrix-workspace.desktop` — `selfservice` launcher
- `wfica.sh` — wrapper for `wfica -file`
- `wfica_assoc.sh` — wrapper for `wfica -associate`
- `ctxcwalogd.service` — systemd unit for the log daemon
- `ctxusbd.service` — systemd unit for the USB daemon

The PKGBUILD's `source=()` references these by basename; the variant is self-contained per the project convention (`pkgbuilds/README.md:3`).
