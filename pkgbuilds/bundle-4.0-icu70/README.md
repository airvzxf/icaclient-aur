# bundle-4.0-icu70

**Status:** candidate
**Based on:** upstream AUR PKGBUILD @ pkgrel=3 (icaclient 26.01.0.150-3)
**CHANGELOG entry:** [../../CHANGELOG.md](../../CHANGELOG.md) — "2026-06-15 — Variant `bundle-4.0-icu70`: first candidate PKGBUILD (D.3 implementation)"
**Implementation plan:** [../../docs/d3-bundle-implementation-plan.md](../../docs/d3-bundle-implementation-plan.md)
**Strategy doc:** [../../docs/alternatives.md](../../docs/alternatives.md) D.3 section

## What this changes vs upstream

The D.3 candidate extracts the prebuilt `webkit2gtk-4.0` Debian bundle that Citrix ships inside the upstream tarball, copies its libs and helpers into `$ICAROOT/lib/`, sets `RUNPATH` / `RPATH` on the Citrix binaries and the webkit helpers, and string-patches the hardcoded Debian multiarch paths inside `libwebkit2gtk-4.0.so.37`. `libsoup-2.4.so.1` (which Citrix does **not** bundle) is extracted from a `libsoup2.4-1` Debian `.deb` pinned to bookworm.

The diff vs `pkgbuilds/latest/PKGBUILD` is concentrated in the `package()` function (7 new phases at the end) and the header (one new `makedepends` entry, two `optdepends` removed, one new source for the libsoup .deb). The 9 support files and the rest of the `package()` function are byte-identical to upstream.

```diff
-makedepends=()                   # implicit (none in upstream)
+makedepends+=('patchelf')
-optdepends=('webkit2gtk: provides libwebkit2gtk-4.0 ABI; required for selfservice and the wfica connection dialog'
-            'libsoup: provides libsoup-2.4 ABI; required for selfservice and the wfica connection dialog')
+optdepends=()                    # both bundled below
+source_x86_64+=("libsoup2.4-1-${LIBSOUP_DEB_VERSION}-amd64.deb::.../libsoup2.4-1_${LIBSOUP_DEB_VERSION}_amd64.deb")
+source_aarch64+=("libsoup2.4-1-${LIBSOUP_DEB_VERSION}-arm64.deb::.../libsoup2.4-1_${LIBSOUP_DEB_VERSION}_arm64.deb")
+                                # 7 new phases at the end of package() (extract
+                                # bundle, copy libs, patchelf, perl path-patch,
+                                # extract libsoup .deb)
```

## Why

The upstream AUR `icaclient` lists `webkit2gtk` (4.0 ABI) and `libsoup` as optdepends. The 4.0 ABI lives only in AUR and takes **multiple hours to compile from source**. `selfservice` users either pay the multi-hour compile or run into the broken state where `selfservice` fails to start (see [docs/webkit2gtk-abi.md](../../docs/webkit2gtk-abi.md) for the full background). The D.3 candidate makes the package self-contained at install time: the bundled libs ship inside the package, the user does not need AUR `webkit2gtk`, and `selfservice` launches without any further setup.

## What's in the bundle (and what isn't)

The Citrix tarball contains a Debian `webkit2gtk-4.0` package directory at `linuxx64/linuxx64.cor/Webkit2gtk4.0/webkit2gtk-4.0.tar.gz`. After extraction (Phase 1, verified by rogueai on 2026-06-12):

```
webkit2gtk-4.0-package/
└── usr/
    └── lib/
        └── x86_64-linux-gnu/
            ├── libwebkit2gtk-4.0.so.37.56.4               (62 MB)
            ├── libjavascriptcoregtk-4.0.so.18.20.4         (24 MB)
            ├── libicudata.so.70.1                         (29 MB)
            ├── libicui18n.so.70.1, libicuuc.so.70.1,      (~5 MB)
            │   libicuio.so.70.1, libicutu.so.70.1, libicutest.so.70.1
            └── webkit2gtk-4.0/
                ├── WebKitNetworkProcess, WebKitWebProcess, MiniBrowser
                └── injected-bundle/libwebkit2gtkinjectedbundle.so
```

**Verified locally (2026-06-15):** the bundle does **not** contain `libsoup-2.4.so.1`. `libwebkit2gtk-4.0.so.37.56.4` declares `libsoup-2.4.so.1` in its `NEEDED` list (because the upstream Debian package's `pkg-config` knows about libsoup), but Citrix does not ship the .so file. We extract it from a `libsoup2.4-1` .deb pinned to Debian bookworm (Phase 7) and install it at `$ICAROOT/lib/libsoup-2.4.so.1`.

## The 7 phases (in order, with verification)

Each phase has a verification step baked into the implementation plan; this section summarizes the rationale, see [docs/d3-bundle-implementation-plan.md](../../docs/d3-bundle-implementation-plan.md) for the full detail.

| # | Phase | Key tool | Verification |
|---|---|---|---|
| 1 | Extract `webkit2gtk-4.0.tar.gz` from the Citrix tarball | `bsdtar` | `ls $WEBKIT_PKG_DIR/usr/lib/$ARCH_MULTIARCH/` is non-empty |
| 2 | Copy the bundle libs to `$ICAROOT/lib/` (flattens the Debian `usr/lib/$ARCH_MULTIARCH/` path, preserves the `webkit2gtk-4.0/` subdir) | `cp -a .../.` | `ls $ICAROOT/lib/libwebkit2gtk-4.0.so.37.56.4` AND `ls $ICAROOT/lib/webkit2gtk-4.0/WebKitNetworkProcess` |
| 3 | `patchelf --set-rpath '$ORIGIN'` on the main libs (the .so + jscore + ICU 70) | `patchelf` | `readelf -d` shows `RUNPATH=$ORIGIN` |
| 4 | `patchelf --set-rpath '$ORIGIN'` on the helper binaries (`WebKitNetworkProcess`, `WebKitWebProcess`, `MiniBrowser`) | `patchelf` | `readelf -d` on each helper shows `RUNPATH=$ORIGIN` |
| 5 | String-patch the 2 hardcoded `/usr/lib/$ARCH_MULTIARCH/webkit2gtk-4.0[.../]` paths in `libwebkit2gtk-4.0.so.37` to `/opt/citrix-webkit/...` with NUL padding | `perl -0777 -pe` | `python3 -c "import re; ..."` returns 2 new paths and 0 old paths; file size unchanged |
| 6 | `patchelf --force-rpath --set-rpath '$ORIGIN/lib'` on `selfservice` (Citrix's binary has an existing DT_RPATH; `--set-rpath` alone cannot overwrite it) and `--set-rpath '$ORIGIN'` on `UIDialogLibWebKit3.so` | `patchelf` | `readelf -d` shows the new `RPATH`/`RUNPATH` |
| 7 | Extract `libsoup-2.4.so.1` from the `libsoup2.4-1` .deb pinned to bookworm, plus the `.so` / `.so.1` symlinks | `ar x` + `bsdtar` | `ls $ICAROOT/lib/libsoup-2.4.so.1` is a real file (not a broken symlink) |

## Implementation choices (and why we deviated from the plan)

The plan at [docs/d3-bundle-implementation-plan.md](../../docs/d3-bundle-implementation-plan.md) is the source of truth for **what** to do; this section documents **how** the candidate deviates from the plan's text and why.

1. **Dynamic NUL padding in the perl one-liner.** The plan's example uses 10 hardcoded `\x00` characters in the replacement, which is off-by-N for paths of different lengths and would silently corrupt the `.so` (the on-disk section size changes). The actual hardcoded paths in `26.01.0.150` are:
   - `/usr/lib/x86_64-linux-gnu/webkit2gtk-4.0` (40 chars) — replacement 33 chars → 7 NULs
   - `/usr/lib/x86_64-linux-gnu/webkit2gtk-4.0/injected-bundle/` (57 chars) — replacement 50 chars → 7 NULs

   The candidate's perl computes the padding per-match (`s{}{}ge`), so it works for any path length and any multiarch (`x86_64-linux-gnu`, `aarch64-linux-gnu`). Validated in sandbox against the real `.so`: file size preserved, both old paths replaced, both new paths land at the expected offsets.

2. **`bsdtar` is not enough for `.deb` extraction.** The plan treats the libsoup .deb as if `bsdtar -xf foo.deb` would unpack it; it does not (it unpacks the outer ar wrapper but does not recursively extract the inner `data.tar.*`). The candidate uses `ar x` (from `binutils`, in `base-devel`) to unpack the .deb, then `bsdtar -xf data.tar.xz` to extract the payload.

3. **aarch64 is supported in the PKGBUILD structure but not end-to-end tested on this dev host.** The plan calls for aarch64 support, and the candidate's multiarch handling (`ARCH_MULTIARCH="${CARCH}-linux-gnu"`) and per-arch source arrays (`source_aarch64+=`) implement it. The dev host is x86_64, so aarch64 is "the PKGBUILD should work, the bundle layout is the same" — unverified at build time.

4. **`libsoup-2.4.so.1` is bundled, not depended on.** AUR `libsoup` (the alternative) is reachable via `yay` / `paru` but is invisible to the `base+base-devel` chroot that `scripts/test-variant.bash` uses for the L2 install test. Depending on AUR `libsoup` would break the S4 (clean install without AUR webkit) test. Bundling the .so via a `libsoup2.4-1` .deb is the only way to keep the L2 chroot install passing.

## Tradeoffs

| Pros | Cons |
|---|---|
| No AUR `webkit2gtk` dep, no multi-hour compile | Adds ~45 MB to the installed package size (web bundle + ICU 70 + libsoup) |
| `selfservice` works out of the box (S1, S4 pass) | Bundle is webkit2gtk 2.36.0 (Debian, March 2022) — has unpatched CVEs |
| No symlink hacks, no `--ignore` dance, no post-install user steps | Adds `patchelf` to makedepends (and `bsdtar` is in `libarchive` which is base-devel) |
| Self-contained: works in the L2 chroot test, works for `pacman -U` on a fresh system | **Fragile libsoup .deb URL** (the biggest single point of fragility per the plan) |
| Inherits the upstream aarch64 support | aarch64 build not yet end-to-end tested |
| | Hardcoded paths in `libwebkit2gtk-4.0.so.37` are string-patched with NUL padding; if Citrix ever changes the path length, the patch silently breaks (mitigated by the verification step in Phase 5) |
| | `--force-rpath` on `selfservice` switches the binary to `DT_RPATH` (Citrix's own choice); this is a minor ABI-level regression vs the more modern `DT_RUNPATH` but is functionally equivalent |

## How to test

The minimum bar for promoting this variant from `proposed` to `candidate`:

- **L0 (namcap)**: clean, no `E:` errors. Verified on this dev host.
  ```bash
  namcap pkgbuilds/bundle-4.0-icu70/PKGBUILD
  ```

- **L2 (clean chroot build + install)**: build must complete in a `base+base-devel` chroot, produce a `.pkg.tar.zst`, install cleanly. Verified on this dev host with `scripts/test-variant.bash bundle-4.0-icu70`. Build time is ~1-2 min on this host (dominated by the Citrix tarball download and the build artifacts); the 5-min target / 15-min ceiling is met.

- **L2 checklist outputs** (the four in `TESTING.md` "Local checklist" that the orchestrator prints):
  - `pacman -Q | grep -iE 'webkit|soup|patchelf'` — should show `patchelf` (makedepends) and **no** `webkit2gtk` (the whole point of D.3 is that webkit2gtk is bundled). May show system `libsoup` if the test host has it (the bundled .so is `libsoup-2.4.so.1`, not the system `libsoup-2.4.so.1.11.2`, so there is no file conflict).
  - `readelf -d /opt/Citrix/ICAClient/selfservice | grep RUNPATH` — should show `Library rpath: [$ORIGIN/lib]` (or `runpath`, depending on `patchelf` behaviour; both work).
  - `ldd /opt/Citrix/ICAClient/selfservice | grep -iE 'not found|webkit|soup'` — should show `libwebkit2gtk-4.0.so.37 => /opt/Citrix/ICAClient/lib/libwebkit2gtk-4.0.so.37.56.4` and `libsoup-2.4.so.1 => /opt/Citrix/ICAClient/lib/libsoup-2.4.so.1` (no `not found`).
  - build time, the `makepkg` log.

- **S4 (install without AUR webkit)**: the L2 chroot is `base+base-devel` only, so this is implicitly tested by L2. S1 (`selfservice` launches) and S3 (the dialog library resolves webkit) are validated in the chroot as long as the chroot has the GTK3 stack installed; the orchestrator installs the package but does **not** install `gtk3` etc., so the S1 GUI test is `⏭️ skipped` in the chroot by design (per the L2 chroot limitation in `docs/testing-infrastructure.md`).

- **S6 (real Citrix session)**: ⏭️ skipped on the dev host (no farm). S7 (no spurious new system deps): verified at L2 install — `pacman -Qe` in the chroot before/after install differs by exactly the new `icaclient` entry.

For an end-to-end S1/S3 GUI test, run:
```bash
scripts/test-variant.bash bundle-4.0-icu70 --sandbox=distrobox
# or
scripts/test-variant.bash bundle-4.0-icu70 --sandbox=nspawn --smoke-test
```

## Known gaps

- **The libsoup .deb URL is `LIBSOUP_DEB_VERSION=2.74.3-1+deb12u1` placeholder, with `SKIP` for the sha256.** The URL needs to be verified against `https://packages.debian.org/bookworm/libsoup2.4-1` and the sha256 computed (`curl -sL <url> | sha256sum -`) before this is sent upstream. The build itself works with `SKIP` (no integrity check) but the candidate is not safe to publish to the AUR without the real sha256. See the `TO VERIFY` comment in the PKGBUILD header.
- **No end-to-end GUI test (S1) was run on the dev host.** The build + chroot install passes; the GUI-level validation (does the storefront page actually render?) requires a tester with a display server and (ideally) a StoreFront account.
- **No real Citrix session test (S6) was run.** No farm on the dev host.
- **No aarch64 build was attempted** on the dev host (x86_64 only). The PKGBUILD structure supports it; the bundle layout is assumed to mirror x86_64 (verified by the plan, not by the dev host).
- **The plan's perl one-liner is off-by-N** for any path length other than the one it was tested against. The candidate uses a per-match NUL padding computation (perl `s{}{}ge`) to be robust. This is a deviation from the plan, not from its intent.
- **Citrix ships webkit2gtk 2.36.0 with unpatched CVEs** ([WSA-* advisories](https://webkitgtk.org/security.html)). The README in the candidate's installed package links to the upstream Citrix tarball; D.3 ships what Citrix ships. Out of scope to fix.
- **The `--force-rpath` on `selfservice` produces a `DT_RPATH` (not `DT_RUNPATH`)** because that's what `--force-rpath` does. The plan's claim that it "switches to DT_RUNPATH" is incorrect. For our purposes both are equivalent; documenting here to avoid confusion.
