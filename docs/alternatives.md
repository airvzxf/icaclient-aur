# Evaluated alternatives for the `webkit2gtk-4.0` dependency

Each alternative is a complete strategy for fixing icaclient's `webkit2gtk-4.0` problem. None is perfect. The goal of this document is to make the tradeoffs of each explicit so that the community can pick one with eyes open.

**Status legend:**
- `candidate` — under active consideration, may be promoted to a `pkgbuilds/<name>/PKGBUILD`
- `accepted` — community agrees, action item
- `rejected` — considered and explicitly ruled out
- `superseded` — replaced by a later alternative
- `informational` — historical record of something tried, not a current option

---

## A. Status quo (current upstream, `webkit2gtk` as optdepend) — informational

**Strategy:** leave the optdepends message as is; users who need selfservice install `webkit2gtk` from AUR manually.

| Pros | Cons |
|---|---|
| No build changes; the AUR maintainer already merged this on 2026-06-11 | Selfservice users still pay the multi-hour compile |
| Works for `wfica`+`.ica` users (the majority?) | Misleading optdepends message (claims only selfservice needs it) |
| | `libsoup` was incorrectly moved to optdepends too on 2026-06-11 (regression) |

**Status:** partially accepted upstream, but needs fixes (see B).

---

## B. Quick fix — revert the `libsoup` regression, keep `webkit2gtk` as optdepend — superseded

**Strategy (was):** revert the 2026-06-11 change that moved `libsoup` to optdepends; explain in the optdepends message that `wfica`'s dialog also needs `webkit2gtk`. Don't touch the bundle idea.

| Pros (were) | Cons (were) |
|---|---|
| Smallest possible change | Doesn't address the multi-hour compile problem |
| Buzo (maintainer) likely to accept quickly | Selfservice users still need AUR webkit2gtk |
| Unblocks users immediately | Doesn't unlock the cleaner D.3 path |

**Status:** **superseded** by the 2026-06-12 finding that `libsoup 2.4` was removed from `[extra]` (see [`CHANGELOG.md`](../CHANGELOG.md) 2026-06-12 entry "Confirmed: `libsoup 2.4` was removed from `[extra]`"). With `libsoup` no longer in `[extra]`, the diff above is no longer applicable — there is no `libsoup` to put in `depends=`. The "interim candidate" path is now D.3 (bundle, with libsoup-2.4 sourced separately — see D.3's "What the bundle does NOT contain") or a "depend on AUR `webkit2gtk`" approach. See A for the current status quo and E for an alternative.

---

## C. Depend on `webkit2gtk-imgpaste` instead of `webkit2gtk` — rejected (cosmetic only)

**Strategy:** Same as status quo but switch the optdepends to `webkit2gtk-imgpaste` (a saner-named fork of AUR `webkit2gtk`).

| Pros | Cons |
|---|---|
| Better package name in the optdepends | Same compile-time problem |
| Cosmetic improvement | Doesn't help selfservice users |

**Status:** rejected as a meaningful improvement; cosmetic only. Not worth a separate variant.

---

## D.3. Bundle the prebuilt webkit2gtk-4.0 from the upstream tarball — candidate (most promising, more complex than initially thought)

**Strategy:** Extract `Webkit2gtk4.0/webkit2gtk-4.0.tar.gz` from the Citrix source tarball (already downloaded by the PKGBUILD), install its libs into `/opt/Citrix/ICAClient/lib/`, use `patchelf` to set RUNPATH on the Citrix binaries and the WebKit helpers so they prefer the bundled libs.

**Discovered by:** rogueai on 2026-06-11 (tarball contains the bundle). **End-to-end attempt by rogueai on 2026-06-12** revealed the implementation is more invasive than initially sketched — see "Implementation reality (2026-06-12)" below.

| Pros | Cons |
|---|---|
| No AUR webkit2gtk dep, no multi-hour compile | Adds ~45-120 MiB to the installed package size (depending on whether we also bundle libsoup-2.4 + transitive deps) |
| Selfservice works out of the box (in theory — rogueai's first attempt got to `selfservice` starting before failing on the injected-bundle path) | Bundle is webkit2gtk 2.36.0 (Debian, March 2022) — has unpatched CVEs since then |
| No symlink hacks, no `--ignore` dance | Adds `patchelf` to makedepends |
| | **Helpers need their own RPATH** (`WebKitNetworkProcess`, `WebKitWebProcess`, `MiniBrowser`) — not in the original sketch |
| | **`libwebkit2gtk-4.0.so.37` has hardcoded paths** to `/usr/lib/x86_64-linux-gnu/webkit2gtk-4.0/...` that must be string-patched at install time — fragile, depends on string length matching with NUL padding |
| | **Need `--force-rpath` on `selfservice`** (Citrix binary already has an RPATH; `--set-rpath` alone won't overwrite it) |
| | **Injected-bundle path must be patched too** (rogueai's first perl attempt missed the second occurrence, leading to `Error loading the injected bundle`) |
| | **`libsoup-2.4.so.1` is NOT in the Debian `webkit2gtk-4.0` package** — it must be sourced separately (or the bundle will fail at runtime with `cannot open shared object file: libsoup-2.4.so.1`) |
| | **Not yet tested end-to-end at the GUI level** — no successful `selfservice` window, no real ICA session |

**Implementation reality (2026-06-12, from rogueai's first end-to-end attempt):**

rogueai's [2026-06-12 07:07 AUR comment](https://aur.archlinux.org/packages/icaclient#comment-1075025) is the first public attempt to actually build D.3 end-to-end. The findings refine the sketch below:

- The Citrix bundle is a Debian `webkit2gtk-4.0` *package directory*, with files under `usr/lib/x86_64-linux-gnu/`. On Arch, we need to flatten the path to `$ICAROOT/lib/`.
- The bundle contains helpers at `usr/lib/x86_64-linux-gnu/webkit2gtk-4.0/{WebKitNetworkProcess, WebKitWebProcess, MiniBrowser, injected-bundle/libwebkit2gtkinjectedbundle.so}`. These need to land at `$ICAROOT/lib/webkit2gtk-4.0/...` (with the same subdirectory structure preserved).
- `libwebkit2gtk-4.0.so.37` has at least three hardcoded `/usr/lib/x86_64-linux-gnu/webkit2gtk-4.0/...` paths (one for each helper binary, one for the injected-bundle). All need to be replaced at install time.
- `selfservice` already has an existing RPATH; `patchelf --set-rpath` (despite the name, this sets RUNPATH) cannot overwrite an existing DT_RPATH. Use `--force-rpath` to switch to RUNPATH and overwrite. rogueai's "doesn't load all dependencies" symptom was exactly this.
- After all the above, `selfservice` starts but fails on `Error loading the injected bundle (/usr/lib/x86_64-linux-gnu/webkit2gtk-4.0/injected-bundle/libwebkit2gtkinjectedbundle.so)`. rogueai's perl one-liner only replaced the FIRST occurrence (no `/g` flag) — that's why the injected-bundle path survived. Fix: use `/g` and patch all occurrences, or use a more targeted binary-rewrite tool.

**What the bundle contains** (verified by extracting the tarball):

| File | Size | Purpose |
|---|---|---|
| `libwebkit2gtk-4.0.so.37.56.4` | 62 MB | Main webkit library |
| `libjavascriptcoregtk-4.0.so.18.20.4` | 24 MB | JavaScript engine |
| `libicudata.so.70.1` | 29 MB | ICU 70 data |
| `libicui18n.so.70.1` | 3 MB | ICU 70 i18n |
| `libicuuc.so.70.1` | 2 MB | ICU 70 unicode |
| `libicuio.so.70.1`, `libicutu.so.70.1`, `libicutest.so.70.1` | <1 MB each | ICU 70 misc |
| `webkit2gtk-4.0/{WebKitNetworkProcess, WebKitWebProcess, MiniBrowser}` | <1 MB each | Helpers spawned by the main lib |
| `webkit2gtk-4.0/injected-bundle/libwebkit2gtkinjectedbundle.so` | <1 MB | Web extension bundle |

**What the bundle does NOT contain** (correction to the 2026-06-11 CHANGELOG entry):

- **`libsoup-2.4.so.1` is NOT in the Debian `webkit2gtk-4.0` package.** `libsoup-2.4` is a separate Debian package (`libsoup2.4-1`) with its own .so. The 2026-06-11 CHANGELOG entry "Citrix ships a prebuilt webkit2gtk-4.0 in the upstream tarball" did not list libsoup as part of the bundle; the 2026-06-12 entry that asserted "the Citrix tarball's `webkit2gtk-4.0.tar.gz` does include `libsoup-2.4.so.1` per the original rogueai finding" was making an unverified claim — there is no such statement in rogueai's 2026-06-11 comment, and Debian's webkit2gtk-4.0 package does not bundle its transitive deps. **For D.3 to be self-contained, `libsoup-2.4.so.1` must be sourced separately** (e.g., extracted from a Debian `libsoup2.4-1` .deb, or pulled in as a transitive dep of AUR `webkit2gtk`, or bundled from a different source — see open questions).

**External system deps the bundle still needs:**

- `libsoup-2.4.so.1` — see "What the bundle does NOT contain" above. **Must be bundled or pulled in from AUR `webkit2gtk`.**
- `libharfbuzz-icu.so.0` ← `harfbuzz-icu` (already a transitive dep of `harfbuzz` for most users)
- Standard GTK3 stack: `gtk3`, `glib2`, `pango`, `cairo`, `gdk-pixbuf2`
- `libxml2`, `libxslt`, `sqlite`, `lcms2`
- `woff2`, `hyphen`, `enchant`, `libmanette`, `libseccomp`, `libnotify`, `libtasn1`, `libgcrypt`
- `gst-plugins-base-libs` and friends (the bundle loads the gst full stack, not just base)
- `libpng`, `libjpeg-turbo`, `libwebp`, `libopenjp2`
- `libXcomposite`, `libXdamage`, `wayland`, `libegl`, `libgl`
- `fontconfig`, `freetype2`, `harfbuzz`, `atk`, `libsecret`

**All** of these are available in Arch `[extra]` or `[community]`, and most users have them as transitive deps of `gtk3` or `firefox`. A minimal chroot build will need to install them explicitly; the depends array of the candidate PKGBUILD may need to grow.

**Implementation sketch (REVISED 2026-06-12 with rogueai's findings):**

```bash
# After the existing `cp -rt "${pkgdir}$ICAROOT" ... lib ...` line in package():

# 1. Extract the Debian webkit2gtk-4.0 package from the Citrix tarball
WEBKIT_TARBALL="$srcdir/linuxx64/linuxx64.cor/Webkit2gtk4.0/webkit2gtk-4.0.tar.gz"
WEBKIT_PKG_DIR="$srcdir/linuxx64/linuxx64.cor/Webkit2gtk4.0/webkit2gtk-4.0-package"
cd "$srcdir/linuxx64/linuxx64.cor/Webkit2gtk4.0"
bsdtar -xf webkit2gtk-4.0.tar.gz
cd "$srcdir"

# 2. Copy the libs (flatten the Debian multiarch path)
cp -a "$WEBKIT_PKG_DIR/usr/lib/x86_64-linux-gnu/." "${pkgdir}$ICAROOT/lib/"

# 3. Set RUNPATH on the main libs (so transitive ICU/jscore lookups stay inside the bundle)
for f in "${pkgdir}$ICAROOT"/lib/libwebkit2gtk-4.0.so.37.56.4 \
         "${pkgdir}$ICAROOT"/lib/libjavascriptcoregtk-4.0.so.18.20.4 \
         "${pkgdir}$ICAROOT"/lib/libicu*.so.70.1; do
    [ -f "$f" ] && patchelf --set-rpath '$ORIGIN' "$f"
done

# 4. Set RUNPATH on the helper binaries (NEW: rogueai 2026-06-12)
# libwebkit2gtk-4.0.so.37 spawns these via exec(); they need to find their sibling libs.
for f in "${pkgdir}$ICAROOT"/lib/webkit2gtk-4.0/{WebKitNetworkProcess,WebKitWebProcess,MiniBrowser}; do
    [ -f "$f" ] && patchelf --set-rpath '$ORIGIN' "$f"
done

# 5. Patch the hardcoded Debian paths inside libwebkit2gtk-4.0.so.37 (NEW: rogueai 2026-06-12)
# The .so has multiple hardcoded references to /usr/lib/x86_64-linux-gnu/webkit2gtk-4.0/
# (one per helper binary, one for the injected-bundle). All must be replaced.
# Use perl with /g to replace ALL occurrences. NUL-pad to keep the same string length.
# rogueai's first attempt omitted /g, leaving the injected-bundle path unpatched.
WEBKIT_SO="${pkgdir}$ICAROOT/lib/libwebkit2gtk-4.0.so.37.56.4"
mkdir -p "${pkgdir}/opt/citrix-webkit"
cp -a "$WEBKIT_PKG_DIR/usr/lib/x86_64-linux-gnu/webkit2gtk-4.0" "${pkgdir}/opt/citrix-webkit/"
perl -0777 -pe '
    s{/usr/lib/x86_64-linux-gnu/webkit2gtk-4.0}
     {/opt/citrix-webkit/webkit2gtk-4.0\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00}g
' -i "$WEBKIT_SO"
# (The NUL padding keeps the .so's section sizes constant so the dynamic loader
#  doesn't break. The replacement is 38 chars + 7 NULs = 45 chars, matching the
#  original 45-char string length. C string functions stop at NUL, so the
#  loader sees "/opt/citrix-webkit/webkit2gtk-4.0".)

# 6. Make Citrix binaries prefer the bundled libs
patchelf --force-rpath --set-rpath '$ORIGIN/lib' "${pkgdir}$ICAROOT/selfservice"   # --force-rpath needed (NEW)
patchelf --set-rpath '$ORIGIN' "${pkgdir}$ICAROOT/lib/UIDialogLibWebKit3.so"
```

Plus changes to the header (`patchelf` to makedepends, removal of `webkit2gtk` optdepend, and **adding a strategy for `libsoup-2.4.so.1`**, see open questions).

**Path patching vs directory replication** (decide before sending to buzo):

The hardcoded paths inside `libwebkit2gtk-4.0.so.37` can be handled two ways:

- **(a) String-patch with NUL padding** (rogueai's approach, sketched above). Pro: helpers live in a natural location chosen by the PKGBUILD. Con: fragile, depends on the string length matching exactly. If Citrix ever updates the bundle and the hardcoded path changes length, the PKGBUILD breaks silently (the .so is silently corrupted — `selfservice` will fail with a confusing error).
- **(b) Replicate the Debian multiarch path** (`/opt/Citrix/ICAClient/usr/lib/x86_64-linux-gnu/webkit2gtk-4.0/`, the original Debian path minus the leading `/usr/`). Pro: no string patching needed; the existing .so code "just works". Con: spreads Citrix files under a non-standard `usr/lib/x86_64-linux-gnu/` path inside `/opt/Citrix/ICAClient/`. Slightly weird, but mirrors what Debian does.

(a) is what rogueai did. (b) is what Debian itself does, and the only one that needs `0` lines of perl. The cleanest is probably (b) for the initial candidate (lowest risk of silent corruption), with a note that (a) is the long-term answer if/when (b)'s path layout proves too ugly.

**Open questions:**

- Does the bundle work with Wayland sessions? (Untested.)
- Does the bundle work with HiDPI / fractional scaling? (Untested.)
- Does Citrix's HDX/Teams optimization still work with this older webkit? (Untested — Citrix may have webkit-version-dependent code paths.)
- Will Citrix ever update the tarball to a newer webkit? (Out of our control.)
- Should the bundled libs be their own AUR sub-package (D.4) so other Citrix clients can reuse them? (Open.)
- **Where does `libsoup-2.4.so.1` come from?** Three candidates: (i) extract from a Debian `libsoup2.4-1` .deb (need a stable URL); (ii) pull from AUR `webkit2gtk` as a transitive dep (defeats some of D.3's "no AUR" appeal); (iii) leave as a system dep, with icaclient's `depends=('libsoup-2.4-1')` pointing at a `*-bin` package we don't have. None is great. **This is the single biggest blocker for a self-contained D.3.**
- **Path patching vs directory replication** (a) vs (b) above. The candidate's first PR should pick one and stick with it; switching later is a pkgbuild bump + a data-migration headache for installed users.
- The original D.3 2026-06-11 entry noted "Tested at ldd level" — this is now an *understatement*. End-to-end at the library-load level it is tested (rogueai did it). End-to-end at the GUI level (selfservice window opens, real session connects) is **not** tested.

**Status:** **most promising** candidate, but the implementation is significantly more complex than the original sketch suggested. Needs end-to-end GUI testing on at least 2-3 different machine configurations before being sent to buzo.

A focused implementation plan that the next session can pick up directly is in [`docs/d3-bundle-implementation-plan.md`](d3-bundle-implementation-plan.md).

---

## D.4. Build precompiled libs in a separate AUR sub-package — proposed (not started)

**Strategy:** Same as D.3 but instead of inlining the libs into `icaclient`, create a separate AUR package `icaclient-webkit2gtk` that provides the bundled libs, and have `icaclient` depend on it.

| Pros | Cons |
|---|---|
| Other packages (e.g., `bin32-citrix-client`, which conflicts with `icaclient` per the current PKGBUILD) could reuse the bundle | More moving parts (two AUR submissions) |
| Can version the webkit bundle independently of icaclient | Needs a separate AUR submission and co-maintenance |

**Status:** not started. Would only make sense if there is community interest in multiple Citrix clients. Given that `bin32-citrix-client` is in the `conflicts=` list, the only realistic consumer is `icaclient` itself, which makes D.4 mostly an exercise in packaging purity.

---

## E. Pre-compile AUR `webkit2gtk` and ship the binary — proposed (new)

**Strategy:** Build `webkit2gtk` from AUR (the current 4.0 ABI build, compiled from upstream WebKitGTK sources) on a maintainer-controlled machine, then redistribute the resulting `.pkg.tar.zst` (~45 MB) as a binary package that end users install in place of compiling AUR `webkit2gtk` themselves. icaclient's PKGBUILD gains a new `optdepends=('webkit2gtk-4.0-bin: ...')` (or `depends=` if we want it to be mandatory) — no multi-hour compile for end users.

**Discovered by:** ironhak on 2026-06-12. ironhak compiled AUR `webkit2gtk` on a 32 GB RAM machine, used `fakepkg` to extract the .pkg.tar.zst, transferred it to a laptop, and installed it cleanly. The package was ~45 MB.

| Pros | Cons |
|---|---|
| Uses a **current** webkit2gtk-4.0 build (not the 2.36.0 Debian blob from 2022 like D.3) | Requires a maintainer-hosted binary blob (~45 MB) — AUR doesn't host prebuilt binaries in normal packages; needs `webkit2gtk-4.0-bin` (AUR, the `firefox-bin` pattern) or a personal repo |
| No multi-hour compile for end users | Binaries are libc-version-locked; need rebuild on each Arch glibc bump |
| No `patchelf` hacks, no `libicu70` quirks, no string-patching of the Debian `.so` | The webkit2gtk-4.0 ABI is upstream-frozen; new builds only close the gap on the 2.x line — newer security fixes may not backport |
| Avoids the 2.36.0 CVE concern that D.3 inherits | Whoever builds the binary becomes a trust anchor — users must trust the build host as much as the AUR maintainer |
| AUR `webkit2gtk` already wires up all the transitive deps (libsoup-2.4, libicu, harfbuzz-icu, gtk3, ...) | The webkit2gtk-4.0 ABI could be dropped from upstream entirely at any point, leaving a stranded `webkit2gtk-4.0-bin` package |
| Test matrix identical to "depend on AUR webkit2gtk" — no new test scenarios needed | Build farm cost (electricity, CI minutes) — non-trivial for a single maintainer |
| | **No one has volunteered to run the build farm.** The "social infrastructure" problem is unsolved. |

**Implementation sketch (NOT final, not started):**

A working E variant needs three pieces:

1. **`webkit2gtk-4.0-bin` AUR package** (or personal repo) that:
   - Has `conflicts=('webkit2gtk', 'webkit2gtk-imgpaste')` and `provides=('webkit2gtk=VERSION')` so icaclient's `optdepends=('webkit2gtk: ...')` resolves to it transparently.
   - Contains the prebuilt `.pkg.tar.zst` files (x86_64 + aarch64 if applicable) as a binary blob. AUR does not allow this normally; a `*.tar.zst` could be in `source=()` pointing at a maintainer-controlled URL.
   - Gets a new release each time Arch's glibc bumps, each time upstream webkit2gtk-4.0 gets a CVE fix, or each time a build-host config changes.
2. **icaclient PKGBUILD change**: nothing in the source — just `optdepends=('webkit2gtk-4.0-bin: ...')` (or `depends=` if we want it to be mandatory). The optdepends message would say "provides precompiled libwebkit2gtk-4.0 ABI; required for selfservice and the wfica connection dialog (faster than compiling `webkit2gtk` from AUR)".
3. **Build host** (a CI machine, a maintainer's workstation, etc.) that:
   - Watches for Arch glibc bumps, upstream webkit2gtk releases, and AUR `webkit2gtk` PKGBUILD updates.
   - Builds AUR `webkit2gtk` cleanly.
   - Runs `fakepkg` (or just `makepkg --allsource --noarchive` + extract) to produce the binary blob.
   - Uploads to the hosting location.

**Open questions:**

- **Where does the binary live?** AUR `webkit2gtk-4.0-bin` (the `firefox-bin` pattern) is the cleanest, but AUR policy generally disallows prebuilt-binary `source=()` in normal AUR packages. A personal repo (`airv_zxf_repo` or similar) bypasses the policy question but trades discoverability for control.
- **Who maintains it?** ironhak suggested it informally on the AUR thread; no one has committed to running a build farm. Without a maintainer, this is a non-starter.
- **How often does it need rebuilding?** At minimum, every glibc bump. Empirically, that's every few months on Arch. Each glibc bump = 32 GB RAM machine + several hours of build time + a re-upload.
- **aarch64?** The current icaclient PKGBUILD supports aarch64; the AUR `webkit2gtk` also supports aarch64; the build farm needs to build both, doubling the cost.
- **Security:** the binary builder is a trust anchor. If compromised, every install is compromised. Mitigations: reproducible builds (deterministic output, signed), public build logs, multiple independent builders that cross-check.
- **D.3 vs E trade-off (for a future implementer):** if the goal is "ship icaclient as a self-contained AUR package right now", D.3 is lower-friction (no build farm, no hosting, no trust anchor). If the goal is "ship icaclient as a self-contained AUR package with current webkit2gtk-4.0 (no 2.36.0 CVEs)", E is the only path. Both are valid; they target different concerns.

**Status:** **proposed.** ironhak has demonstrated the approach works for one person transferring a binary to another machine. Making it a maintainable package for the Arch community is a different problem (build farm, hosting, trust). **No candidate PKGBUILD exists yet.** D.3 is the lower-friction option for the same goal.

---

## Things that were tried and don't work

- **`webkit2gtk-4.1` as a replacement** (codemonkey777, mag37, Drake): causes libsoup-2/libsoup-3 conflict. [verified]
- **Symlink `libwebkit2gtk-4.0.so.37 → libwebkit2gtk-4.1.so.0`**: appears to work for wfica+ica, crashes for selfservice. [verified]
- **Symlink `libjavascriptcoregtk-4.0.so.18 → libjavascriptcoregtk-4.1.so.0`**: same as above. [verified]
- **`--assume-installed webkit2gtk` with webkit2gtk-4.1 installed**: same as the symlink hack.
- **Removing `webkit2gtk` entirely and relying on `wfica` + .ica files only**: works for that workflow, breaks selfservice (which ironhak and the original poster cannot avoid).

---

## What we haven't tried yet (open for proposals)

- D.3 with the bundle from a different webkit2gtk-4.0 build (e.g., a more recent 4.0 ABI build from a non-Debian source). If anyone has a newer 4.0 ABI build handy, the patchelf loop in D.3 is the only thing that needs to change. (Note: this is what E explores with the AUR `webkit2gtk` build, but E is a hosting/trust problem, not a packaging problem.)
- Patching `UIDialogLibWebKit3.so` at install time to use `webkit2gtk-4.1` (not just symlinking, but rewriting the NEEDED entries via `patchelf --replace-needed`). Fragile but possible. The libsoup-2 vs libsoup-3 conflict means this would also need `patchelf --replace-needed` for libsoup, and that would break other Citrix code that legitimately uses libsoup-2. Not recommended.
- File an upstream request to Citrix to bundle a newer webkit2gtk in the tarball. Long shot, but worth doing.

---

## Promotion criteria (when does a candidate become "send to buzo"?)

A `pkgbuilds/<name>/PKGBUILD` is ready to send upstream only when **all** of the following are true:

1. The variant has been built locally by the proposer without errors.
2. At least 2 independent testers have run the full [TESTING.md](../TESTING.md) scenario set (S1 through S6 at minimum) on different machine configurations, with all green or all documented as "out of scope for this variant".
3. The CHANGELOG.md entry for the variant is complete: rationale, tradeoffs, evidence.
4. The depends/optdepends/makedepends arrays have been reviewed by at least one other contributor for completeness.
5. The diff vs the upstream AUR PKGBUILD is small and easy to review (the goal is a 5-line patch, not a 50-line refactor).

Until then, the variant is "in development" and lives under `pkgbuilds/` for further iteration.
