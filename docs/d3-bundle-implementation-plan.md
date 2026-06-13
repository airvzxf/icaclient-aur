# D.3 bundle implementation plan

A focused plan for the [`bundle-4.0-icu70`](../pkgbuilds/README.md) candidate (or whatever name it gets) that the next session can pick up directly. This is a planning doc, not a strategy doc — the strategy lives in [`alternatives.md`](alternatives.md) D.3 section. This doc captures the **concrete steps**, the **concrete files**, and the **concrete pitfalls** the next implementer will hit.

## Goal

Ship a `pkgbuilds/bundle-4.0-icu70/PKGBUILD` (or similar name) that:
- Extracts `Webkit2gtk4.0/webkit2gtk-4.0.tar.gz` from the Citrix source tarball (already downloaded by the PKGBUILD).
- Installs the bundled libs + helpers at `$ICAROOT/lib/`.
- Patches the hardcoded paths in `libwebkit2gtk-4.0.so.37` so the helpers resolve.
- Sets RUNPATH on the Citrix binaries (`selfservice`, `UIDialogLibWebKit3.so`) and the helper binaries (`WebKitNetworkProcess`, `WebKitWebProcess`, `MiniBrowser`).
- Selfservice launches without needing AUR `webkit2gtk` installed.

## Why this plan exists

The strategy-phase `docs/alternatives.md` D.3 sketch is now a high-level summary. The actual implementation is ~60-80 lines of bash + perl + careful `install()` step. This plan is the missing layer between "sketch" and "PR". The next session should:

1. Create `pkgbuilds/bundle-4.0-icu70/{PKGBUILD,README.md}`.
2. Copy the implementation steps from this doc.
3. Add `scripts/lib/test-variant.bash` invocation per the existing testing protocol.
4. Open a PR.

## Source materials (re-read these before writing code)

- **`docs/alternatives.md` D.3 section** — the strategy, the pros/cons, the bundle contents table, the implementation sketch (revised 2026-06-12 with rogueai's findings). This doc is the source of truth for "why".
- **`CHANGELOG.md` 2026-06-12 entries**:
  - "D.3 implementation sketch revised based on rogueai's first end-to-end attempt" — the 4 findings (helpers, hardcoded paths, --force-rpath, directory structure) and the libsoup correction.
  - "Confirmed: `libsoup 2.4` was removed from `[extra]`" — the libsoup-2.4 ABI must come from somewhere.
- **AUR comments** (read these in the browser, not the repo, since they're not committed):
  - [rogueai 2026-06-12 07:07](https://aur.archlinux.org/packages/icaclient#comment-1075025) — the actual patchelf work that surfaced the 4 findings. Read the perl one-liner carefully.
  - [ironhak 2026-06-12 13:37](https://aur.archlinux.org/packages/icaclient#comment-1075087) — the fakepkg approach (alternative E). May inform the libsoup sourcing.
- **`docs/webkit2gtk-abi.md`** — background on the libsoup-2.4 ABI and why we can't substitute.
- **`pkgbuilds/latest/PKGBUILD`** — the upstream PKGBUILD this candidate diffs against. Don't reinvent the parts that are unchanged.

## Bundle structure (verified by rogueai)

After `bsdtar -xf linuxx64/linuxx64.cor/Webkit2gtk4.0/webkit2gtk-4.0.tar.gz`:

```
linuxx64/linuxx64.cor/Webkit2gtk4.0/webkit2gtk-4.0-package/
├── usr/
│   └── lib/
│       └── x86_64-linux-gnu/
│           ├── libwebkit2gtk-4.0.so.37.56.4     (62 MB)
│           ├── libjavascriptcoregtk-4.0.so.18.20.4  (24 MB)
│           ├── libicudata.so.70.1               (29 MB)
│           ├── libicui18n.so.70.1               (3 MB)
│           ├── libicuuc.so.70.1                 (2 MB)
│           ├── libicuio.so.70.1, libicutu.so.70.1, libicutest.so.70.1
│           └── webkit2gtk-4.0/
│               ├── WebKitNetworkProcess         (<1 MB)
│               ├── WebKitWebProcess             (<1 MB)
│               ├── MiniBrowser                  (<1 MB)
│               └── injected-bundle/
│                   └── libwebkit2gtkinjectedbundle.so  (<1 MB)
```

(The aarch64 bundle has a different layout — the variant should support both, but x86_64 is the priority.)

## Implementation steps (6 phases, in order)

Each phase has a verification step. If verification fails, do NOT proceed to the next phase.

### Phase 1: Extract the bundle

```bash
WEBKIT_TARBALL="$srcdir/linuxx64/linuxx64.cor/Webkit2gtk4.0/webkit2gtk-4.0.tar.gz"
WEBKIT_PKG_DIR="$srcdir/linuxx64/linuxx64.cor/Webkit2gtk4.0/webkit2gtk-4.0-package"

cd "$srcdir/linuxx64/linuxx64.cor/Webkit2gtk4.0"
bsdtar -xf webkit2gtk-4.0.tar.gz
cd "$srcdir"
```

**Verify:** `ls $WEBKIT_PKG_DIR/usr/lib/x86_64-linux-gnu/` should list the libs. If empty, the tarball path is wrong (Citrix may have changed it between releases) — fail early.

### Phase 2: Copy the libs to `$ICAROOT/lib/`

```bash
cp -a "$WEBKIT_PKG_DIR/usr/lib/x86_64-linux-gnu/." "${pkgdir}$ICAROOT/lib/"
```

This flattens the Debian `usr/lib/x86_64-linux-gnu/` path but **preserves the `webkit2gtk-4.0/` subdirectory** (so the helpers end up at `$ICAROOT/lib/webkit2gtk-4.0/...`, not `$ICAROOT/lib/...`).

**Verify:** `ls ${pkgdir}$ICAROOT/lib/libwebkit2gtk-4.0.so.37.56.4` exists AND `ls ${pkgdir}$ICAROOT/lib/webkit2gtk-4.0/WebKitNetworkProcess` exists. If only one is there, the `cp -a` didn't preserve the subdirectory.

### Phase 3: Set RUNPATH on the main libs

```bash
for f in "${pkgdir}$ICAROOT"/lib/libwebkit2gtk-4.0.so.37.56.4 \
         "${pkgdir}$ICAROOT"/lib/libjavascriptcoregtk-4.0.so.18.20.4 \
         "${pkgdir}$ICAROOT"/lib/libicu*.so.70.1; do
    [ -f "$f" ] && patchelf --set-rpath '$ORIGIN' "$f"
done
```

**Verify:** `readelf -d ${pkgdir}$ICAROOT/lib/libwebkit2gtk-4.0.so.37.56.4 | grep -E "RPATH|RUNPATH"` should show `$ORIGIN`. If empty, `patchelf` is missing from makedepends.

### Phase 4: Set RUNPATH on the helper binaries (NEW vs original sketch)

```bash
for f in "${pkgdir}$ICAROOT"/lib/webkit2gtk-4.0/{WebKitNetworkProcess,WebKitWebProcess,MiniBrowser}; do
    [ -f "$f" ] && patchelf --set-rpath '$ORIGIN' "$f"
done
```

**Verify:** `readelf -d ${pkgdir}$ICAROOT/lib/webkit2gtk-4.0/WebKitNetworkProcess | grep RUNPATH` should show `$ORIGIN`. If the helpers don't have an RPATH, the `libwebkit2gtk-4.0.so.37` will fail to spawn them (they'll fail to find sibling libs).

### Phase 5: Patch the hardcoded paths in `libwebkit2gtk-4.0.so.37` (NEW vs original sketch)

This is the most fragile step. Two viable strategies, see the "Path patching vs directory replication" section in [`docs/alternatives.md`](alternatives.md) D.3.

**Strategy (a): NUL-padded string replacement** (what rogueai did, with the `/g` fix)

```bash
WEBKIT_SO="${pkgdir}$ICAROOT/lib/libwebkit2gtk-4.0.so.37.56.4"
mkdir -p "${pkgdir}/opt/citrix-webkit"
cp -a "$WEBKIT_PKG_DIR/usr/lib/x86_64-linux-gnu/webkit2gtk-4.0" "${pkgdir}/opt/citrix-webkit/"
perl -0777 -pe '
    s{/usr/lib/x86_64-linux-gnu/webkit2gtk-4.0}
     {/opt/citrix-webkit/webkit2gtk-4.0\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00}g
' -i "$WEBKIT_SO"
```

**Verify:** `strings $WEBKIT_SO | grep -E "webkit2gtk-4.0"` should show NO occurrences of `/usr/lib/x86_64-linux-gnu/webkit2gtk-4.0` (the original Debian path) and SHOULD show `/opt/citrix-webkit/webkit2gtk-4.0`. If the original Debian path is still present, the perl regex didn't fire — most likely the `/g` flag was forgotten again (rogueai's bug) or the NUL padding broke the regex.

**Verify (more rigorous):** `ldd $WEBKIT_SO` should NOT show any `libicu*.so.70.1 => not found` (the .so should resolve its OWN deps via RUNPATH). And `python3 -c "import re; data = open('$WEBKIT_SO','rb').read(); print(re.findall(rb'/opt/citrix-webkit/webkit2gtk-4.0[^\x00]*', data))"` should return a non-empty list (this is the runtime path the .so will dlopen from).

**Strategy (b): Replicate the Debian multiarch path** (no string patching)

```bash
# The helpers live at $ICAROOT/lib/webkit2gtk-4.0/...
# We need them at /usr/lib/x86_64-linux-gnu/webkit2gtk-4.0/... to match
# the hardcoded path. Create that path inside $ICAROOT.
mkdir -p "${pkgdir}$ICAROOT/usr/lib/x86_64-linux-gnu"
cp -a "$WEBKIT_PKG_DIR/usr/lib/x86_64-linux-gnu/webkit2gtk-4.0" \
    "${pkgdir}$ICAROOT/usr/lib/x86_64-linux-gnu/"

# But the hardcoded path is /usr/lib/... (absolute), not $ICAROOT/usr/lib/...
# So we still need a symlink or a string patch.
# (a) Symlink:  ln -s ../lib/webkit2gtk-4.0 \
#                  ${pkgdir}$ICAROOT/usr/lib/x86_64-linux-gnu/webkit2gtk-4.0
# (b) String patch: same as strategy (a) above, but with the new path
```

Strategy (b) is conceptually cleaner but requires more filesystem gymnastics. **Pick (a) for the initial candidate; the perl is one line and the verification is clear.**

### Phase 6: Make Citrix binaries prefer the bundled libs (with --force-rpath)

```bash
patchelf --force-rpath --set-rpath '$ORIGIN/lib' "${pkgdir}$ICAROOT/selfservice"
patchelf --set-rpath '$ORIGIN' "${pkgdir}$ICAROOT/lib/UIDialogLibWebKit3.so"
```

**Verify:** `readelf -d ${pkgdir}$ICAROOT/selfservice | grep RUNPATH` should show `$ORIGIN/lib`. The `--force-rpath` is **mandatory** — without it, `selfservice`'s existing DT_RPATH survives and the bundled libs are not preferred (rogueai's "doesn't load all dependencies" bug).

**Verify (end-to-end at ldd level):** install the package in a clean chroot, then `ldd /opt/Citrix/ICAClient/selfservice | grep -iE "webkit|soup|icu"`. Every entry should resolve to either `/opt/Citrix/ICAClient/lib/...` (bundled) or a system path. If anything shows `=> not found`, a previous phase missed something.

## What the bundle does NOT contain (and the libsoup question)

The Debian `webkit2gtk-4.0` package does not bundle its transitive deps. **`libsoup-2.4.so.1` is NOT in the bundle.** A self-contained D.3 must source libsoup-2.4 from somewhere. Three options, none perfect:

1. **Extract from a Debian `libsoup2.4-1` .deb.** Need a stable URL (Debian's pool, snapshot.debian.org, etc.). The PKGBUILD downloads and unpacks. Pros: self-contained. Cons: another tarball to maintain, another source URL to pin, another piece that can break.

2. **Depend on AUR `webkit2gtk-imgpaste` (or `webkit2gtk`).** Pros: simple, single `depends+=('webkit2gtk-imgpaste')`. Cons: brings the multi-hour compile back for the user (defeats the point), and brings back the 2.36.0 vs current debate. The "AUR `webkit2gtk`" already provides libsoup-2.4 as a transitive dep, so this works but isn't really D.3 anymore.

3. **Bundle `libsoup-2.4.so.1` from a separate source.** E.g., extract from the same Debian pool as a `libsoup2.4-1` .deb but as a separate download. Pros: same as (1) but doesn't conflate with webkit. Cons: same.

**Recommendation for the first candidate:** start with (1) (download a `libsoup2.4-1` .deb alongside the Citrix tarball). This makes the candidate truly self-contained. Document the URL and sha256sum carefully — this is the single biggest point of fragility.

If (1) is too fragile in practice, fall back to (2) and document that D.3 is no longer self-contained. The candidate's README should be explicit about which path it takes.

## Header changes

The candidate's `PKGBUILD` needs the following changes vs `pkgbuilds/latest/PKGBUILD`:

- **`makedepends+=('patchelf')`** — for the RUNPATH / --force-rpath operations.
- **`makedepends+=('bsdtar')`** — for extracting the inner `webkit2gtk-4.0.tar.gz`. (May already be in `base-devel`; check.)
- **`optdepends-=('webkit2gtk: ...')`** — no longer needed; the bundle provides webkit2gtk-4.0 itself.
- **`optdepends-=('libsoup: ...')`** — no longer needed if libsoup-2.4 is bundled per the libsoup question above. If not, change the libsoup optdep message to clarify it points at the bundled `libsoup-2.4.so.1` (which needs nothing from outside).
- **New source for the libsoup .deb** (if going with option 1 above). Add to `source=()` and `sha256sums=()`.

Don't change `pkgname`, `pkgver`, `pkgrel` semantics — the variant is a *delta* on top of upstream, not a fork.

## Test matrix

Before sending the candidate to buzo, the candidate must pass:

| Scenario | Test | Expected |
|---|---|---|
| S1 | `selfservice` launches in L3 sandbox (per `docs/testing-infrastructure.md`) | GUI window appears; no `cannot open shared object file` |
| S2 | `wfica sample-pna.ica` (per `scripts/test-fixtures/`) | `.ica` parsed, TCP connection attempt to `192.0.2.1:1494` (non-routable) |
| S3 | `WebKitWebProcess` becomes a child of `selfservice` / `wfica` | Per the smoke test in `scripts/lib/citrix-smoke.bash` |
| S4 | Install in a clean chroot (no AUR `webkit2gtk` installed) | `pacman -U` succeeds; S1-S3 pass |
| S5 | Build time | <5 min target, <15 min ceiling |
| S7 | `pacman -Qe` before/after | Difference = only the new icaclient entry; `webkit2gtk` is NOT pulled in as a dep (since we removed it from optdepends) |

**Minimum for the candidate to be sent to buzo: S1, S2, S4, S5. The other scenarios are nice-to-have.**

S6 (real Citrix session) requires a real farm; treat as `⏭️ skipped` per the existing protocol.

## Open questions for the implementer

These are documented in the CHANGELOG's "Open questions" section and in `docs/alternatives.md`. The implementer should be aware of them but does not need to resolve them in the first candidate:

- **Path patching strategy:** (a) NUL-pad string replacement vs (b) replicate Debian multiarch path. Pick (a) for now; switch to (b) only if (a) is too fragile in practice.
- **libsoup-2.4 sourcing:** option (1) (download .deb), (2) (depend on AUR), or (3) (bundle separately). Pick (1) for now.
- **aarch64 support:** the upstream PKGBUILD supports aarch64. The candidate should too. The Citrix tarball has a separate `linuxarm64-*.tar.gz` with its own `Webkit2gtk4.0/` directory. Verify the aarch64 bundle has the same structure before duplicating the patchelf loop.
- **CVEs in the bundled 2.36.0:** document in the README that this ships an old webkit2gtk with unpatched CVEs. The README should link to https://webkitgtk.org/security.html and note that Citrix's tarball is what it is. D.3 ships what Citrix ships.

## Out of scope (do NOT do in this candidate)

- **Adding `lldpd` or `bind` to optdepends.** That's the `pkgbuilds/opt-lldpd-bind/` candidate, a separate variant.
- **E (fakepkg approach).** Different strategy, different candidate.
- **Migrating `pkgbuilds/latest/PKGBUILD` to a different version of upstream Citrix tarball.** Stick to `26.01.0.150-3` (the current upstream at the time of this doc).
- **Adding x86_64 / aarch64 / runtime CI.** The candidate is tested manually by humans (per the existing test matrix protocol).

## Estimated time to first PR

For someone familiar with the codebase (i.e., has read the docs in this repo): 4-6 hours. The implementation is mostly mechanical (copy-paste the phases above, with verification between each). The slow parts are the libsoup sourcing (option 1) and the first end-to-end test in a chroot.

For someone new: 1-2 days, mostly reading the docs.
