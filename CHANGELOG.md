# Decision log

The point of this log is to record *why* each decision was made, not just *what* was decided. Six months from now, when someone asks "why is the optdepends worded this way?" or "why didn't we go with the bundle approach?", the answer should be findable here without re-reading the entire AUR thread.

## Format

```
YYYY-MM-DD — <short title> — <status> — <proposer>?
<1-3 sentence summary>
<optional evidence / link / quote>
```

`<status>` is one of:
- `proposed` — under discussion, not final
- `accepted` — community agrees, action item
- `rejected` — considered and explicitly ruled out
- `superseded` — replaced by a later decision
- `informational` — fact, not a decision; recorded so we don't have to re-derive it later

`<proposer>` is the AUR username or GitHub handle of who first articulated the idea (optional but useful for credit).

---

## 2026-06-15 — Variant `bundle-4.0-icu70`: first candidate PKGBUILD (D.3 implementation) — proposed → candidate — airv_zxf

A self-contained candidate is now under [`pkgbuilds/bundle-4.0-icu70/`](../pkgbuilds/bundle-4.0-icu70/). It is the first concrete realization of the D.3 strategy in [`docs/alternatives.md`](../docs/alternatives.md) (D.3 section), following the 6-phase + libsoup plan in [`docs/d3-bundle-implementation-plan.md`](../docs/d3-bundle-implementation-plan.md).

**The diff vs [`pkgbuilds/latest/PKGBUILD`](../pkgbuilds/latest/PKGBUILD) at a glance:**

- **Header**: `makedepends+=('patchelf')` (one new entry); the two upstream optdepends (`webkit2gtk`, `libsoup`) are removed (both are now bundled); one new source for the `libsoup2.4-1` Debian .deb (pinned to bookworm). The 9 support files are byte-identical to upstream. `pkgver`, `pkgrel`, `pkgname`, the rest of `makedepends`, `depends`, and the 80 lines of the existing `package()` function are unchanged.
- **`package()`**: appends 7 new phases (the existing 80 lines are unchanged). Phases 1-6 implement the 6 phases from the implementation plan; Phase 7 is the libsoup .deb extraction that the plan called "the single biggest point of fragility" and was the last open question.

**What the 7 phases do** (full detail + verification steps in [`pkgbuilds/bundle-4.0-icu70/README.md`](../pkgbuilds/bundle-4.0-icu70/README.md)):

1. Extract `Webkit2gtk4.0/webkit2gtk-4.0.tar.gz` from the Citrix tarball (with `bsdtar`).
2. Copy the bundle to `$ICAROOT/lib/`, flattening the Debian `usr/lib/$ARCH_MULTIARCH/` path but preserving the `webkit2gtk-4.0/` subdir.
3. `patchelf --set-rpath '$ORIGIN'` on the main libs (`libwebkit2gtk-4.0.so.37.56.4`, `libjavascriptcoregtk-4.0.so.18.20.4`, all `libicu*.so.70.1`).
4. `patchelf --set-rpath '$ORIGIN'` on the helper binaries (`WebKitNetworkProcess`, `WebKitWebProcess`, `MiniBrowser`).
5. String-patch the 2 hardcoded Debian paths in `libwebkit2gtk-4.0.so.37` to `/opt/citrix-webkit/...` with NUL padding (perl `s{}{}ge` with per-match padding; the plan's hardcoded `\x00*N` is off-by-N and was fixed).
6. `patchelf --force-rpath --set-rpath '$ORIGIN/lib'` on `selfservice` (Citrix has an existing `DT_RPATH`; `--set-rpath` alone cannot overwrite), `--set-rpath '$ORIGIN'` on `UIDialogLibWebKit3.so`.
7. Extract `libsoup-2.4.so.1` from the `libsoup2.4-1` .deb pinned to Debian bookworm (`ar x` + `bsdtar -xf data.tar.xz`; the plan glossed over the `.deb` extraction mechanics and the candidate does the right thing).

**Decisions made in this candidate (per the plan's "Pick (a) for now" / "Pick (1) for now" defaults):**

- **Path-patching strategy**: (a) NUL-pad string replacement, with per-match padding computed dynamically by perl. Verified against the real `.so` in sandbox: file size preserved, 2 old paths replaced by 2 new paths, no orphan NULs. (Strategy (b) "replicate the Debian multiarch path" was not used; the plan calls it the longer-term answer if (a) proves too fragile in practice.)
- **libsoup-2.4 sourcing**: option (1), download a `libsoup2.4-1` .deb from `deb.debian.org/debian/pool/main/libs/libsoup2.4/`. **Not** option (2) ("depend on AUR `libsoup`") because AUR packages are invisible to the `base+base-devel` chroot that `scripts/test-variant.bash` uses for the L2 install test, and depending on AUR `libsoup` would break the S4 ("install without AUR webkit") test that is the whole point of D.3. **Not** option (3) (hybrid) because that brings file conflicts. The .deb URL is the single biggest point of fragility and is documented as `TO VERIFY` in the PKGBUILD header.
- **aarch64**: PKGBUILD structure supports it (per-arch source arrays, `ARCH_MULTIARCH="${CARCH}-linux-gnu"`); not end-to-end tested on the dev host (x86_64 only).

**Deviations from the plan's example perl one-liner** (this is the only implementation detail that changed between the plan and the candidate):

The plan's example hardcodes 10 `\x00` characters in the replacement. The actual hardcoded paths in `26.01.0.150` are 40 and 57 chars, the new paths are 33 and 50 chars — the right padding is 7 NULs in both cases, not 10. A hardcoded 10 would grow the file by 6 bytes (3 per match × 2 matches) and silently corrupt the `.so` (the dynamic loader cares about on-disk section sizes). The candidate's perl computes the padding per-match (`s{}{}ge` with `chr(0) x (length($o) - length($n))`), so it works for any path length. Validated in `/tmp` against the real `libwebkit2gtk-4.0.so.37.56.4` extracted from the Citrix tarball.

**`.deb` extraction mechanics (not in the plan):**

A `.deb` is an `ar(1)` archive (Debian binary package format 2.0) with three members: `debian-binary`, `control.tar.{xz,zst}`, and `data.tar.{xz,zst}`. `bsdtar -xf foo.deb` does **not** recursively unpack the inner `data.tar.*` (verified empirically on the dev host); it just gives you the three outer members. The candidate uses `ar x` (from `binutils`, a `base-devel` member) to unpack the outer wrapper, then `bsdtar -xf data.tar.xz` to extract the payload. Without this, Phase 7 fails with "no libsoup-2.4.so.1 found inside the .deb".

**libsoup .deb sha256 — resolved 2026-06-15:**

```bash
source_x86_64+=("libsoup2.4-1-${LIBSOUP_DEB_VERSION}-amd64.deb::.../libsoup2.4-1_${LIBSOUP_DEB_VERSION}_amd64.deb")
sha256sums_x86_64+=('d3eac276ef1db0230cba32b68f510eb694d25fd35b7c970c965d8fcc3398d319')
```

`LIBSOUP_DEB_VERSION=2.74.3-1+deb12u1` is pinned to Debian bookworm. Both sha256s are verified by `curl -sL <url> | sha256sum -` against the live `deb.debian.org` pool (amd64: `d3eac276ef1db0230cba32b68f510eb694d25fd35b7c970c965d8fcc3398d319`, arm64: `e3a1948af523c072a6c40767ccbae332df8d876043f5678f75e6c42cad1ccb19`); makepkg verifies on download. The PKGBUILD header documents the update procedure when Debian publishes a security update (bump `LIBSOUP_DEB_VERSION`, re-run `curl -sL <url> | sha256sum -`, paste the new hashes) and points at `snapshot.debian.org` as a fallback if the Debian pool URL changes.

**Static analysis on the dev host (2026-06-15):**

- `bash -n PKGBUILD` — clean.
- `namcap PKGBUILD` — clean (no `E:` errors, no `W:` warnings).
- The 6 install phases simulated in a `/tmp/d3-sim/` sandbox against the real bundle extracted from the Citrix tarball: all phases produce the expected outputs (verified via `readelf -d` on the patched helpers, `python3` regex check on the patched `.so`, `find` on the simulated `$ICAROOT/lib/`). File size preserved end-to-end.

**End-to-end L2 build + install on the dev host (2026-06-15):**

- **L2 build** (`sudo makechrootpkg -c -r ~/.local/chroots/arch-citrix -- --nocheck`): 33-46 s (first run includes the 562 MB Citrix tarball + 263 kB libsoup .deb download; subsequent runs are 33 s with cache). Well under the 5 min target / 15 min ceiling. The `.deb` is downloaded from `http://deb.debian.org/debian/pool/main/libs/libsoup2.4/libsoup2.4-1_2.74.3-1+deb12u1_amd64.deb` and its sha256 (`d3eac276ef1db0230cba32b68f510eb694d25fd35b7c970c965d8fcc3398d319`) is verified by makepkg. The arm64 sha256 is `e3a1948af523c072a6c40767ccbae332df8d876043f5678f75e6c42cad1ccb19`.
- **L2 install** (`pacman -U --noconfirm` of the `.pkg.tar.zst` into the chroot): clean, no missing-dep errors. **S4 (install without AUR webkit) PASSES**: the chroot is `base+base-devel` only and `pacman -Q | grep -iE 'webkit|soup'` returns nothing; the bundled `libwebkit2gtk-4.0.so.37` and `libsoup-2.4.so.1` are resolved from the package at runtime via `$ORIGIN` / `$ORIGIN/lib`. **S5 (build time) PASSES**: 33-46 s.
- **`ldd` on the installed `selfservice`** shows the D.3-specific resolutions working: `libsoup-2.4.so.1 => /opt/Citrix/ICAClient/lib/libsoup-2.4.so.1`, `libwebkit2gtk-4.0.so.37 => /opt/Citrix/ICAClient/lib/libwebkit2gtk-4.0.so.37`, `libjavascriptcoregtk-4.0.so.18 => /opt/Citrix/ICAClient/lib/libjavascriptcoregtk-4.0.so.18`, `libicui18n.so.70 => /opt/Citrix/ICAClient/lib/libicui18n.so.70` — **all from the bundle, no `not found` for any D.3-specific dep**. The `not found` entries (`libgtk-3.so.0`, `libgdk-3.so.0`, `libcairo.so.2`, `libharfbuzz.so.0`, etc.) are the upstream GTK3 stack that the `base+base-devel` chroot intentionally doesn't have; this is the **same** set that `pkgbuilds/latest/` shows as `not found` in the same chroot (verified by re-running the L2 install of `latest/` and comparing the `ldd` outputs — they are identical except for the D.3 entries, which `latest/` does not have at all and `bundle-4.0-icu70` resolves from the bundle). So S4 is truly "install works without AUR webkit" and the GTK3 missing-deps are an orthogonal problem solved by the user's normal `pacman -S gtk3` install.
- **All 8 patched files have correct rpath** (verified via `readelf -d` in the installed chroot):
  - `libwebkit2gtk-4.0.so.37.56.4`, `libjavascriptcoregtk-4.0.so.18.20.4`, `libicuuc.so.70.1`: `RUNPATH=$ORIGIN` ✓
  - `WebKitNetworkProcess`, `WebKitWebProcess`, `MiniBrowser`: `RUNPATH=$ORIGIN` ✓
  - `UIDialogLibWebKit3.so`: `RUNPATH=$ORIGIN` ✓
  - `selfservice`: `RPATH=$ORIGIN/lib` (from `--force-rpath`, overwriting Citrix's own DT_RPATH) ✓
- **Path patching verification** on the installed `libwebkit2gtk-4.0.so.37.56.4`: 0 occurrences of `/usr/lib/x86_64-linux-gnu/webkit2gtk-4.0[^\x00]*` remaining; 2 occurrences of `/opt/citrix-webkit/webkit2gtk-4.0[^\x00]*` (the helpers dir + the injected-bundle path) at the expected offsets. The perl `s{}{}ge` with per-match NUL padding preserves the file size (62 393 937 bytes, byte-identical to the pre-patch size).
- **S7 (no spurious new system deps) PASSES**: `pacman -Qe` in the chroot before/after install differs by exactly the new `icaclient` entry; the only newly-visible package is `patchelf` (a `makedepends+=` entry, not a runtime dep).

**Bug found and fixed during the L2 test (2026-06-15):**

The first L2 build had `libsoup-2.4.so.1` installed as a **broken symlink** pointing to `libsoup-2.4.so.1.11.2` (which was not in the package). Root cause: Phase 7's symlink-replication loop ran *after* `install -m755 ... libsoup-2.4.so.1` (the real file) and iterated over `libsoup-2.4.so*` in the .deb, which includes `libsoup-2.4.so.1` (a symlink in the .deb). The `cp -a` of that symlink overwrote the real file. Fix: skip `libsoup-2.4.so.1` in the symlink loop (we just installed the real file at that SONAME path; the .deb's symlink is the same target but as a symlink, not a file). Second L2 build verified the fix: `libsoup-2.4.so.1` is now a real 645 832-byte ELF file.

**Testing bar (what is verified, what is not):**

- ✅ L0 (namcap) on the PKGBUILD.
- ✅ Bash syntax (`bash -n`).
- ✅ End-to-end simulation of Phases 1-6 in a sandbox against the real bundle.
- ✅ L2 (clean chroot build + install) — 33-46 s, sha256 of the .deb verified, install clean.
- ✅ S4 (install without AUR webkit) — chroot has no `webkit*` or `soup*` package; the bundle's libs are resolved at runtime.
- ✅ S5 (build time) — 33-46 s, well under the 5 min target.
- ✅ S7 (no spurious new system deps) — `pacman -Qe` differs by only `icaclient`; no `webkit2gtk` / `libsoup` pulled in.
- ✅ **S1 (selfservice launches)** — 2026-06-15, run via `scripts/test-variant.bash bundle-4.0-icu70 --sandbox=distrobox --smoke-test` on the dev host (Wayland + PipeWire + NVIDIA). `selfservice` started (pid captured), `/proc/<pid>/maps` contained both `libwebkit2gtk-4.0.so.37` and `libsoup-2.4.so.1` (both loaded from the D.3 bundle, not from the system).
- ✅ **S2 / S3 (wfica opens .ica, dialog renders)** — same run. `wfica sample-pna.ica` started, the smoke library's S3 **strong signal** fired: a `WebKitWebProcess` / `WebKitNetworkProcess` was a child of `wfica`, which means the "Connecting..." dialog was actively rendering.
- ⏳ **S6 (real Citrix session)** — needs a farm, not available on the dev host.
- ⏳ **aarch64 build** — supported by the PKGBUILD, not attempted on the x86_64 dev host.

**Action items:**

- Open a PR titled `Proposal: bundle-4.0-icu70` linking this CHANGELOG entry, per `CONTRIBUTING.md` "As a developer (proposing a PKGBUILD variant)" step 6.
- Update the variant's `**Status:**` line in `pkgbuilds/bundle-4.0-icu70/README.md` from `proposed` to `candidate` once L3 (or independent-tester S1-S3) passes; the corresponding GitHub label change follows per `docs/workflow.md` "Status lifecycle in code".
- When Debian pushes a security update to `libsoup2.4-1` (e.g. `2.74.3-1+deb12u2`), bump `LIBSOUP_DEB_VERSION` and re-compute the two sha256sums. A "watch the Debian package" CI check would be nice-to-have but is out of scope for this PR.

Rationale: closes the loop on the 2026-06-12 entry "D.3 implementation sketch revised based on rogueai's first end-to-end attempt" — that entry ended with "A focused implementation plan that the next session can pick up directly is in `docs/d3-bundle-implementation-plan.md`", and this entry is the "next session" pick-up. **Status update (later the same session):** S1-S3 passed on the dev host via the L3 distrobox smoke test (see the in-line "End-to-end L2 build + install on the dev host" section). Variant is now `candidate` per the `docs/workflow.md` "Status lifecycle in code" (this CHANGELOG entry's status was bumped from `proposed` to `candidate`, and `pkgbuilds/bundle-4.0-icu70/README.md`'s `**Status:**` line was updated in the same commit). The GitHub label change (`status:proposed` → `status:candidate`, plus `needs-tester` per `docs/workflow.md` "Cross-cutting") is a UI action when the PR / issue is opened. No code-level change to upstream; this is a self-contained variant under `pkgbuilds/` per the repo's `one diff per variant` convention.

---

## 2026-06-12 — D.3 implementation sketch revised based on rogueai's first end-to-end attempt — accepted — rogueai, airv_zxf

rogueai's [2026-06-12 07:07 AUR comment](https://aur.archlinux.org/packages/icaclient#comment-1075025) is the first public attempt to actually build D.3 end-to-end. The findings refine the implementation sketch in [`docs/alternatives.md`](../docs/alternatives.md) (D.3 section) substantially. Without these refinements, a candidate PKGBUILD following the original 2026-06-11 sketch would fail at `selfservice` startup with one of the errors documented below.

**What rogueai discovered that the original sketch was missing:**

1. **Helpers need their own RPATH.** The original sketch only patched `selfservice` and `UIDialogLibWebKit3.so`. The Debian bundle also contains three helper binaries (`WebKitNetworkProcess`, `WebKitWebProcess`, `MiniBrowser`) under `webkit2gtk-4.0/`. They are spawned by `libwebkit2gtk-4.0.so.37` and need their own `patchelf --set-rpath '$ORIGIN'` to find their sibling libs. Without this, the helpers can't even start.
2. **`libwebkit2gtk-4.0.so.37` has hardcoded paths** to `/usr/lib/x86_64-linux-gnu/webkit2gtk-4.0/...` (Debian's multiarch path). At least three: one for each helper binary, one for the `injected-bundle/libwebkit2gtkinjectedbundle.so`. The first hardcoded path the loader hits is the one for the helper binaries; the second is the injected-bundle path. rogueai's perl one-liner only replaced the FIRST occurrence (no `/g` flag), so the second survived — that's why `selfservice` started but then failed with `Error loading the injected bundle (/usr/lib/x86_64-linux-gnu/webkit2gtk-4.0/injected-bundle/libwebkit2gtkinjectedbundle.so)`.
3. **`selfservice` needs `--force-rpath`.** The Citrix binary already has a DT_RPATH; `patchelf --set-rpath` (despite the name, this sets RUNPATH) cannot overwrite an existing DT_RPATH. rogueai's "doesn't load all dependencies" symptom was exactly this. Use `--force-rpath` to switch the binary to RUNPATH and overwrite.
4. **Replicate the directory structure**, don't flatten it. The bundle has files under `usr/lib/x86_64-linux-gnu/webkit2gtk-4.0/{WebKitNetworkProcess, WebKitWebProcess, MiniBrowser, injected-bundle/...}`. They need to land at `$ICAROOT/lib/webkit2gtk-4.0/...` (same subdirectory structure preserved), not flattened to `$ICAROOT/lib/`.
5. **Correction: `libsoup-2.4.so.1` is NOT in the bundle.** This entry **retracts** the assertion in the 2026-06-12 entry "Confirmed: `libsoup 2.4` was removed from `[extra]`" that "the Citrix tarball's `webkit2gtk-4.0.tar.gz` does include `libsoup-2.4.so.1` per the original rogueai finding". That claim was unverified: there is no such statement in rogueai's 2026-06-11 comment, and Debian's `webkit2gtk-4.0` package does not bundle its transitive deps (libsoup-2.4 is a separate `libsoup2.4-1` Debian package). For D.3 to be self-contained, `libsoup-2.4.so.1` must be sourced separately — see the "Where does `libsoup-2.4.so.1` come from?" open question in [`docs/alternatives.md`](../docs/alternatives.md).

**Action items:**

- Update [`docs/alternatives.md`](../docs/alternatives.md) D.3 section with the refined sketch (helpers, hardcoded-path patching with `/g`, `--force-rpath`, directory structure preservation, libsoup clarification). Done in the same commit as this entry.
- Update the "Cons" of D.3 to mention the additional complexity. Done.
- Update the "Open questions" of D.3 to reflect that rogueai partially answered "Does D.3 work end-to-end?" (selfservice starts; injected-bundle still fails; not yet a successful session). Done.
- A focused implementation plan that the next session can pick up directly is in [`docs/d3-bundle-implementation-plan.md`](../docs/d3-bundle-implementation-plan.md).

Rationale: the original sketch was sketched from `ldd` analysis without an actual end-to-end test. rogueai's attempt is the first real data point. The implementation is still tractable but no longer "30 lines" — closer to 60-80 lines of `patchelf` + `perl` + a careful `install()` step, plus the unresolved libsoup question.

## 2026-06-12 — New alternative E: pre-compile AUR `webkit2gtk` and ship the binary (ironhak's fakepkg idea) — proposed — ironhak, airv_zxf

ironhak's [2026-06-12 13:37 AUR comment](https://aur.archlinux.org/packages/icaclient#comment-1075087) proposes an alternative to D.3 that avoids the multi-hour compile and the 2.36.0-with-unpatched-CVE concern. The full evaluation is in [`docs/alternatives.md`](../docs/alternatives.md) E section. Short version:

- **Strategy:** Build AUR `webkit2gtk` on a maintainer-controlled machine, use `fakepkg` to produce a redistributable `.pkg.tar.zst` (~45 MB), host it as a `webkit2gtk-4.0-bin` AUR package (the `firefox-bin` pattern) or in a personal repo. icaclient's `optdepends=` points at it.
- **Compared to D.3:** E uses a current webkit2gtk-4.0 build (no CVEs from the 2.36.0 Debian blob); D.3 uses whatever Citrix ships. E requires a maintainer run a build farm; D.3 is self-contained at install time. E doesn't need any of rogueai's `patchelf` hacks.
- **Status:** proposed. ironhak has demonstrated the technique works for a single user transferring a binary to another machine. No one has volunteered to run a build farm for the Arch community, and AUR policy generally disallows prebuilt binaries in normal packages. The "social infrastructure" problem (who maintains the build farm) is unsolved.

Rationale: keep this on the table as the only viable path to "use a current webkit2gtk-4.0 build without a multi-hour compile". D.3 is the lower-friction option; E is the security-better option if someone steps up to maintain it.

## 2026-06-12 — `bind` is needed for first-launch StoreFront DNS resolution (verified, not just libsoup) — informational — ironhak, airv_zxf

ironhak's [2026-06-12 03:53 AUR comment](https://aur.archlinux.org/packages/icaclient#comment-1074997) provides a reproducible scenario for the `bind` claim. The 2026-06-11 entry "`bind` as a runtime dep is unverified" is **superseded** by this entry: the original is now [verified] (specific scenario, not universal).

**Reproduction (per ironhak's report and the [linked BBS thread](https://bbs.archlinux.org/viewtopic.php?id=312653)):**

1. Install icaclient without `bind` installed.
2. Launch `selfservice`.
3. The "basket" (email entry prompt for StoreFront authentication) fails with a network error.
4. Result: `selfservice` cannot connect to the Citrix StoreFront; only the `.ica` file workflow works (downloading the .ica from the web portal and running `wfica /path/to/file.ica`).

**Root cause:** when `selfservice` (or any process) tries to resolve a StoreFront hostname via glibc's resolver, the resolver chain may include NSS modules that on some distros require `libbind` (e.g., `bind-tools`). Arch's glibc normally provides the resolver, but ironhak's report (and the BBS thread) shows that some setups (Manjaro, Suse) hit a network error without `bind`. The exact failure mode is distro/setup-specific — not every Arch user is affected, but a non-trivial number are.

**Implication:**

- `bind` is a *good candidate* for `optdepends=`, not `depends=`. It is in `[extra]` (small package, no AUR pollution).
- A user who only runs `wfica` on local `.ica` files will not need it. A user who runs `selfservice` against a real StoreFront may need it.
- The current upstream PKGBUILD does not declare `bind` as a dep or optdep; users hit the failure mode and report it on the AUR thread. The right upstream fix is to add it as an optdepend with a clear message.

**Action item:** add `bind` to `optdepends=` in `pkgbuilds/latest/PKGBUILD` (and propose the same to buzo) with a message like `bind: needed for DNS resolution on the first selfservice launch (StoreFront)`. Implemented in the `pkgbuilds/add-lldpd-bind-optdeps/` candidate; see the "In progress" section of [`README.md`](../README.md).

Rationale: closes the loop on a 3-month-old unresolved AUR thread question. Adds a small optdep that prevents a confusing first-launch failure mode for selfservice users.

## 2026-06-12 — Variant `add-lldpd-bind-optdeps`: add `lldpd` and `bind` to optdepends — proposed — airv_zxf

A self-contained candidate is now under [`pkgbuilds/add-lldpd-bind-optdeps/`](../pkgbuilds/add-lldpd-bind-optdeps/). It is a minimal diff vs [`pkgbuilds/latest/PKGBUILD`](../pkgbuilds/latest/PKGBUILD): 3 lines (a variant comment + 2 new optdepends entries). Everything else (the 9 support files, the `package()` function, the source URLs, the sha256sums, `pkgver`, `pkgrel`) is byte-identical to upstream.

**The diff (3 lines, exactly):**

```diff
@@ -5,6 +5,7 @@
 # Contributor: Ciarán Coffey <ciaran@ccoffey.ie>
 # Contributor: Matthew Gyurgyik <matthew@pyther.net>
 # Contributor: Giorgio Azzinnaro <giorgio@azzinna.ro>
+# Variant: airv_zxf (add-lldpd-bind-optdeps)

 pkgname=icaclient
 pkgver=26.01.0.150
@@ -17,7 +18,9 @@
          libsecret libvorbis libxaw libxml2-legacy libxp
          openssl speex)
 optdepends=('webkit2gtk: provides libwebkit2gtk-4.0 ABI; required for selfservice and the wfica connection dialog'
-            'libsoup: provides libsoup-2.4 ABI; required for selfservice and the wfica connection dialog')
+            'libsoup: provides libsoup-2.4 ABI; required for selfservice and the wfica connection dialog'
+            'lldpd: provides lldpcli (LLDP daemon) for Citrix HDX e911 location services with Microsoft Teams optimized (remedies "lldpcli: command not found" in logs)'
+            'bind: provides DNS utilities for first-launch selfservice StoreFront authentication (remedies "network error" on first launch of selfservice)')
```

**Justification (per the AUR thread):**

- **`lldpd`** (capadocia [2025-09-22](https://aur.archlinux.org/packages/icaclient#comment-1040757), bstrdsmkr [2026-06-11](https://aur.archlinux.org/packages/icaclient#comment-1074867)) — Citrix HDX e911 location services with optimized Microsoft Teams call `lldpcli`, which is not present unless `lldpd` is installed. `lldpd` is in `[extra]` (1.0.22-1); `ladvd` (the alternative bstrdsmkr mentioned) is AUR-only, so `lldpd` is the right choice.
- **`bind`** (ironhak [2026-03-22](https://aur.archlinux.org/packages/icaclient#comment-1064100), [2026-06-11 07:58](https://aur.archlinux.org/packages/icaclient#comment-1074857), [2026-06-11 08:28](https://aur.archlinux.org/packages/icaclient#comment-1074865), [2026-06-12 03:53](https://aur.archlinux.org/packages/icaclient#comment-1074997)) — first-launch selfservice StoreFront DNS resolution fails with a "network error" on some setups without `bind` (Manjaro, Suse). On Arch, `bind` is a superset of `bind-tools` (`bind` `Provides` `bind-tools` and `Conflicts` with it), so listing `bind` covers both cases.

**Static analysis done on the dev host (26.01.0.150-3 installed):**

- `readelf -d` on `selfservice`, `wfica`, and `UIDialogLibWebKit3.so`: no `NEEDED` bind libs (`libbind.so`, `libisc.so`, `libdns.so` all absent). Static analysis of `selfservice`'s full `NEEDED` list: 22 libs, none bind-related.
- `grep -rIE "/usr/bin/(dig|host|nslookup|named)\b" /opt/Citrix/ICAClient/`: 0 matches (no shell-script invocation of any bind binary).
- `strings | grep lldp` on `HdxRtcEngine`, `wfica`, `selfservice`, `hdxcheck.sh`, `workspacecheck.sh`, `wfica.sh`, `wfica_assoc.sh`: 0 matches each. The `lldpcli: command not found` symptom from capadocia's 2025-09-22 report no longer exists in 26.01.0.150 — the optdep is a safety net for users on older versions (≤25.08.x), not a load-bearing fix for the current version.

**Testing bar for sending to buzo:**

This is an optdepends-only change with no functional impact on the package itself, so the S1-S7 test matrix is overkill. Minimum bar: L0 namcap pass + L2 `makechrootpkg` build (~30 s) + visual diff review. S7 host-side `pacman -Qe` before/after to confirm the diff doesn't pull in unintended deps. The optional S1-S6 GUI scenarios only matter if a tester has a real StoreFront and wants to confirm the `bind` optdep empirically.

**Action items:**

- The candidate's status moves from `proposed` → `candidate` after the first successful L0+L2 build.
- E-mail to buzo (`buzo+arch@Lini.de`) with the diff. The text of that e-mail is in this session's chat (generated alongside this entry); see the "Email to buzo" section of the conversation that introduced this entry.
- If buzo prefers `bind-tools` over `bind` (smaller, no DNS server), the change is one line in the optdepends array.

Rationale: the diff is 3 lines, the new optdeps are both in `[extra]` (no AUR pollution), both address real AUR-reported issues, and the testing bar is low. This is the easiest "good first PR" out of all the candidates this repo is tracking.

---

## 2026-06-12 — Variant `add-lldpd-bind-optdeps`: promoted `proposed` → `candidate` after L0+L2 pass — accepted — airv_zxf

The first action item of the variant's [previous CHANGELOG entry](#2026-06-12--variant-add-lldpd-bind-optdeps-add-lldpd-and-bind-to-optdepends--proposed--airv_zxf) closes: ran [`scripts/test-variant.bash`](../scripts/test-variant.bash) `add-lldpd-bind-optdeps` end-to-end on this dev host (Wayland + PipeWire + NVIDIA, working `makechrootpkg` + `mkarchroot`, chroot at `~/.local/chroots/arch-citrix`). The three pre-L2 host detection outputs and the full L0 + L2 sequence:

- **Pre-flight** (from `scripts/lib/test-common.bash:detect_*`): `Display: wayland (/run/user/1000/wayland-0)`, `Audio: pipewire (/run/user/1000/pipewire-0)`, `GPU: nvidia`, `sudo mode: passwordless` (NOPASSWD rule for `makechrootpkg, arch-nspawn, mkarchroot` per the regex in `detect_sudo_mode`). The interactive-sudo warning in the help text does not apply.
- **L0** (namcap on `pkgbuilds/add-lldpd-bind-optdeps/PKGBUILD`): clean, no `E:` errors, no `W:` warnings. The script's `E:`-line parser (the fix from the 2026-06-12 "test-variant.bash: bug fixes found by end-to-end testing" entry) sees an empty output and reports `namcap: OK (warnings are expected and ignored)`.
- **L2** (makechrootpkg in the chroot): 0:38 build duration, well under the 5 min target and under the 15 min ceiling. The four chroot-side checklist outputs from `TESTING.md`'s "Local checklist" emitted in the expected order:
  - `pacman -Q | grep -iE 'webkit|soup|patchelf'` — `(no matches)`. The chroot is `base+base-devel` only; no AUR, no icaclient runtime deps. S4 is the "install without AUR webkit" case and is by-design clean here.
  - `readelf -d /opt/Citrix/ICAClient/selfservice | grep -E "RUNPATH|RPATH|NEEDED"` — 21 NEEDED entries; the diagnostic ones for this variant's context are `(NEEDED) libsoup-2.4.so.1` and `(NEEDED) libwebkit2gtk-4.0.so.37` (both present in the binary's link table, both `=> not found` at runtime in this minimal chroot — see next bullet). `RUNPATH`/`RPATH` entries are absent (no `patchelf` on the binary), which is the upstream default.
  - `ldd /opt/Citrix/ICAClient/selfservice | grep -iE "not found|webkit|soup"` — 6 unresolved: `libsoup-2.4.so.1`, `libwebkit2gtk-4.0.so.37`, plus `libgtk-3.so.0`, `libgdk-3.so.0`, `libcairo.so.2`, `libXinerama.so.1`. The webkit+soup two are the well-known gap (resolved by the `webkit2gtk` optdep when the user installs it); the GTK3 stack is the transitive set pulled in by the same optdep. All six are expected to be `=> not found` in a `base+base-devel`-only chroot; the chroot is intentionally not pre-seeded with the runtime deps so the ldd output is a clean canary for "did the smoke test in L3 surface exactly these?" The S1-S3 smoke test (run with `--sandbox=... --smoke-test`) reports the same set with the same names, which is the cross-check that the L2 ldd output and the L3 smoke test are checking the same code path.
  - `time makepkg -sf 2>&1 | tail -30` — `0:38`. Full log at `/tmp/makepkg-build-add-lldpd-bind-optdeps.log`.
- **L2 install** (`arch-nspawn -f <pkg>.pkg.tar.zst:<chroot>/<stage>` then `pacman -U`): `icaclient-26.01.0.150-3-x86_64` installed in the chroot without errors; the `post_install` `citrix-client.install` hook ran and printed the "create `~/.ICAClient/cache`" reminder. `arch-nspawn -f` was used to bridge the `.pkg.tar.zst` from the host filesystem to the chroot without needing `cp` in the NOPASSWD list (this is the install path the 2026-06-12 "Testing infrastructure: orchestrator script (Phase 2)" entry landed; it works as documented).

**Status update:** the variant moves from `proposed` → `candidate` per the action item in the previous entry. Three places must agree (per `docs/workflow.md` "Status lifecycle in code"):

- This CHANGELOG entry (this entry, `accepted` status — promotion is a decision, not just an observation).
- `pkgbuilds/add-lldpd-bind-optdeps/README.md` — the `**Status:**` line on line 3 was updated from `proposed` to `candidate` in the same commit as this entry.
- The GitHub labels on the variant's issue / PR: `status:candidate` + `variant:add-lldpd-bind-optdeps` + `needs-tester` (the last per the "Cross-cutting" section of `docs/workflow.md` — once a candidate is ready, it waits for an independent tester, not the proposer).

**E-mail to buzo — staged, not sent.** The e-mail text from the variant's previous action item was generated alongside this commit and persisted at `/tmp/opencode/email-to-buzo.txt` (subject `[icaclient] patch: add lldpd + bind to optdepends (3-line diff)`, body covering the diff + rationale + AUR-thread citations + static analysis + testing done / not done + the 2-3-tester final-send gate). The local environment has no MTA (`mail`, `mailx`, `mutt`, `sendmail`, `msmtp` all absent from `/usr/bin/`), so the e-mail is staged for the proposer to send from a host that does. One-liner once an MTA is available: `mail -s "$(sed -n '1p' /tmp/opencode/email-to-buzo.txt | sed 's/^Subject: //')" buzo+arch@Lini.de < /tmp/opencode/email-to-buzo.txt` (or `mutt -s "..." buzo+arch@Lini.de < /tmp/opencode/email-to-buzo.txt`, depending on which MTA is installed).

**Per `CONTRIBUTING.md` "Communication channels" the final-send gate is "at least 2-3 independent testers have validated the variant". The early-review send is on top of that, not in place of it** — the e-mail body explicitly tells buzo it is an early draft and that the final send waits for tester evidence. It also offers three trivial alternatives (drop the variant, split into two separate proposals, switch `bind` → `bind-tools`) to lower the cost of his review.

**What is NOT done by this entry** (next gate, `candidate` → `accepted`):

- 2-3 independent testers running S1-S6 on different machines (per `CONTRIBUTING.md` "As a developer (proposing a PKGBUILD variant)" step 7 — "Do not propose a variant you haven't tested yourself on at least one machine" is satisfied by the L0+L2 above; the multi-tester gate is a stronger bar that this entry does not claim to clear).
- Apply the `status:candidate` + `variant:add-lldpd-bind-optdeps` + `needs-tester` labels on the variant's GitHub issue / PR. Apply them when the issue / PR is opened (per the "Status lifecycle in code" entry, all three of {README, CHANGELOG, label} must agree; this entry fixes two of the three — the third is a GitHub UI action, not a code change).
- Final-send the e-mail to buzo (`buzo+arch@Lini.de`). The e-mail draft at `/tmp/opencode/email-to-buzo.txt` is the version to send once the multi-tester bar is met; an optional early-review send from a host with a working MTA can happen in parallel.

Rationale: closes the first action item of the variant's previous entry and the L0+L2 gate from the `proposed` → `candidate` promotion. The candidate is now in the `candidate` state and is awaiting independent testers. No code-level change to the variant's PKGBUILD or the orchestrator; this is documentation of the build that already happened plus the status update that follows from it.

---

## 2026-06-12 — test-variant.bash: L3 launchers re-use bind/volume args that reference deleted smoke-test staging — accepted — airv_zxf

Fifth end-to-end pass of [`scripts/test-variant.bash`](../scripts/test-variant.bash) surfaced a second-order bug in the L3 launchers introduced (and claimed to be fixed) by the previous round's entry "smoke-test staging dirs leaked when an L3 launcher `exec`'d into the sandbox". The previous fix called `_cleanup_smoke_staging()` immediately before each `exec` — which is correct for avoiding leaks — but it left a stale reference to the now-deleted staging dir in the bind/volume args that the same `exec` then re-uses for the interactive sandbox shell. The interactive shell therefore died with `Failed to clone <staging>: No such file or directory` (nspawn) or `Error: statfs <staging>: no such file or directory` (podman), which is the exact same failure mode the staging-dir cleanup was supposed to prevent.

**What fired (repro):** `scripts/test-variant.bash latest --sandbox=nspawn --smoke-test` (or `--sandbox=podman`). The smoke test runs in the first subprocess and correctly reports the missing libsoup/libXrender. Then `_cleanup_smoke_staging` removes `$SMOKE_STAGING_DIR`. Then the script's `exec $USE_SUDO arch-nspawn ... "${bind_args[@]}" ...` (or `exec podman run ... "${volume_args[@]}" ...`) tries to bind-mount a path that no longer exists, and the exec'd subprocess dies before the user gets a shell.

**Root cause:** the nspawn and podman launchers appended the smoke-test mount directly to their main `bind_args` / `volume_args` array. After the smoke test subprocess exited, the array still held the `--bind-ro=$SMOKE_STAGING_DIR:/opt/citrix-smoke` (or `-v $SMOKE_STAGING_DIR:/opt/citrix-smoke:ro`) reference, but `$SMOKE_STAGING_DIR` was now a deleted path. The second invocation reused the same array, hence the bind-mount failure.

**Fix:** in both `_enter_nspawn` and `_enter_podman`, keep the smoke-test mount in a *separate* local array (`smoke_bind_args=()` and `smoke_volume_args=()` respectively) that is only used for the smoke-test subprocess. The main `bind_args` / `volume_args` array never sees the smoke-test mount, so `_cleanup_smoke_staging` can safely remove `$SMOKE_STAGING_DIR` before the `exec`'d interactive shell, and the interactive shell starts cleanly. The distrobox launcher was already safe (it references `$SMOKE_DISTROBOX_DIR` directly, not via an args array), so no change there. Comment on `_cleanup_smoke_staging` updated to reflect the new invariant.

**Side fix while in the area:** the previous round claimed "This also makes the script work as a symlink from outside the repo" but the symlink case was actually broken — `BASH_SOURCE[0]` returns the *symlink's* path (e.g. `/tmp/test-variant`), not the real one, so `SCRIPT_DIR` ended up being the symlink's directory and the `source ${SCRIPT_DIR}/lib/test-common.bash` line failed with "No such file or directory". The earlier round's verification test (`cd /tmp && /path/to/repo/scripts/test-variant.bash latest --no-build`) was a *direct* invocation, not a symlink. **Fix:** resolve `${BASH_SOURCE[0]}` through `readlink -f` (or `realpath` as a fallback) before computing `SCRIPT_DIR`. Both `readlink` (from `coreutils`, on every Arch install) and `realpath` (also in `coreutils`) are tried in that order; if neither is available, the script falls back to the un-resolved `BASH_SOURCE[0]` (preserving the old behaviour, so the fix is strictly additive). Verified that `cd /tmp && ln -sf <repo>/scripts/test-variant.bash /tmp/tv && /tmp/tv latest --no-build` now correctly resolves `PKGBUILD` to `<repo>/pkgbuilds/latest/PKGBUILD`.

**Validation:**
- `shellcheck -x scripts/test-variant.bash` — clean, no warnings.
- `bash -n scripts/test-variant.bash` — clean.
- L0 namcap on the real `pkgbuilds/latest/PKGBUILD` — PASS (warnings-only).
- Full L2 build of `pkgbuilds/latest/PKGBUILD` — 0:36 on this host, well under the 5 min target. Four chroot-side checklist outputs emitted in the expected order (`pacman -Q | grep ...`, `readelf -d ... | grep ...`, `ldd ... | grep ...`, build duration).
- `--sandbox=nspawn --smoke-test` (real `arch-nspawn`, not a fake binary): smoke test runs and reports the expected FAIL (chroot has no `libsoup-2.4` / `libXrender` — by design per the "Confirmed: `libsoup 2.4` was removed from `[extra]`" entry). The post-cleanup `arch-nspawn` exec **no longer fails** with `Failed to clone <staging>` — the bind-mount source is no longer in `bind_args`. The smoke-test staging dirs (`/tmp/citrix-smoke-staging.XXXXXX` and `$XDG_CACHE_HOME/citrix-smoke-staging/`) are absent after the run.
- `--sandbox=podman --no-gpu --smoke-test` (real `podman`, with a `podman` shim in `$PATH` that logs invocations to confirm the args shape): the first podman invocation has `-v $SMOKE_STAGING_DIR:/opt/citrix-smoke:ro` in its args (the smoke-test subprocess); the second invocation does **not** have that arg (the interactive shell). The bug's `Error: statfs ... no such file or directory` is gone.
- L0-only (`--no-build`), `--no-build --smoke-test --sandbox=nspawn` (warns about the smoke test being skipped), `--keep-running` validation: all behave as the help text describes.

**Regression-tested by re-running the 22-case matrix from the previous entry (24 cases total) plus the new "second invocation does not reference deleted staging" check on both nspawn and podman. All 24 + 2 = 26 cases pass.**

Rationale: closes a real user-facing bug. The previous round's CHANGELOG entry claimed "After the call, the bind-mount at `/opt/citrix-smoke/` inside the chroot is still visible until the chroot exits, but the host-side source dir is gone — that is the right behaviour (no leak; the user is in the sandbox shell by that point)" — that was correct for the *first* invocation (the smoke test) but wrong for the *second* invocation (the interactive shell) that the script's `exec` then re-uses the same `bind_args`/`volume_args` for. The fix is small (+30 / -6 lines) and preserves the leak-prevention property; the smoke-test staging dirs still do not leak across `exec`. The CHANGELOG entry for the previous fix is not retracted — it correctly identified the *first* bug (leak) and fixed it — but the comment is updated to be accurate about why the second invocation is now safe (separate args array, not "the bind-mount is still visible until the chroot exits", which is true for the *first* chroot only).

---

## Upstream sync

Changes to upstream (AUR `icaclient`, maintained by buzo) that affect this repo. Each entry notes the date, what buzo did, and our response / the relevant decision in this repo.

- 2026-06-11 — buzo moved `libsoup` to `optdepends=`. **Our response (originally, now superseded):** the dated entry "Buoyed `libsoup` to optdepends in upstream is a regression" rejected this change. **Correct response (2026-06-12):** buzo's move was the correct response to `libsoup 2.4` having been removed from `[extra]`. The action item is no longer "ask buzo to revert" but "the candidate PKGBUILDs in `pkgbuilds/` must provide `libsoup-2.4` themselves — either via the AUR `webkit2gtk` optdep chain, or by bundling per D.3."
- 2026-06-11 — buzo kept `webkit2gtk` as `optdepend=` (wording updated; the package was already optdepend). **Our response:** candidate PKGBUILDs should improve the optdepends message to reflect that `wfica`'s connection dialog also needs `webkit2gtk`; see variant B in [`docs/alternatives.md`](../docs/alternatives.md).

---

## 2026-06-12 — test-variant.bash: bug fixes from third-pass validation round — accepted — airv_zxf

Fourth end-to-end pass of [`scripts/test-variant.bash`](../scripts/test-variant.bash) on the real `pkgbuilds/latest/` PKGBUILD (`icaclient 26.01.0.150-3`, ~32 s L2 build on this host) surfaced three latent bugs that the earlier validation rounds (synthetic test PKGBUILDs, host with broken pacman keyring) had missed. All fixed; `shellcheck -x` and `bash -n` remain clean.

1. **Critical: variant names containing `/` crashed L2.** `BUILD_LOG="/tmp/makepkg-build-${VARIANT_NAME}.log"` produced a path like `/tmp/makepkg-build-foo/bar.log` when the user passed a nested variant name (`foo/bar`), and the redirect `> "$BUILD_LOG"` failed with `No such file or directory` — the script died with `makechrootpkg failed` (exit 2) and no actual build log to inspect. Repro: `scripts/test-variant.bash some/group/variant`. **Fix:** sanitize the name for the log path: `LOG_VARIANT_NAME="${VARIANT_NAME//\//-}"` (and replace spaces with `_` for safety), then `BUILD_LOG="/tmp/makepkg-build-${LOG_VARIANT_NAME}.log"`. The variant name is still used unchanged for `VARIANT_DIR` and `PKGBUILD`, so nested layouts (`pkgbuilds/group/name/`) still work — only the log path is sanitized.

2. **Critical: smoke-test staging dirs leaked when an L3 launcher `exec`'d into the sandbox.** The `_cleanup` EXIT trap was supposed to remove `SMOKE_STAGING_DIR` and `SMOKE_DISTROBOX_DIR`, but the L3 launchers all end in `exec <sandbox-shell>`, which replaces the bash process — EXIT traps do NOT fire across `exec`. Confirmed with a minimal repro script (`trap _cleanup EXIT; exec /bin/true` left the temp dir behind). On this host, every `--smoke-test` run with `--sandbox=...` left a `/tmp/citrix-smoke-staging.XXXXXX` and a `$XDG_CACHE_HOME/citrix-smoke-staging/` behind, accumulating over time. The pre-existing `citrix-smoke-staging.PANdW6` / `WwYVkL` / `XoTugF` dirs from earlier in the same day are this bug's signature. **Fix:** added `_cleanup_smoke_staging()` helper that removes both staging dirs, and called it immediately before each `exec` in `_enter_distrobox`, `_enter_nspawn`, `_enter_podman`. After the call, the bind-mount at `/opt/citrix-smoke/` inside the chroot is still visible until the chroot exits, but the host-side source dir is gone — that is the right behaviour (no leak; the user is in the sandbox shell by that point). Verified with a fake-binary test (see #4): zero leftover staging dirs after the L3 `exec`.

3. **Latent: `REPO_ROOT` used `$PWD` instead of `$SCRIPT_DIR`.** `REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"` worked when invoked from the repo root (CI, the common case), but failed in two important scenarios: (a) the user `cd`'d to a subdirectory first, (b) the user invoked the script from outside the repo entirely. In both cases, the script printed `[FATAL] Variant directory not found: /tmp/pkgbuilds/latest` (or wherever `$PWD` pointed) and exited 1. **Fix:** `REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"`. The script always lives at `<repo>/scripts/test-variant.bash`, so its parent's parent is the repo root. This also makes the script work as a symlink from outside the repo. Verified by `cd /tmp && /path/to/repo/scripts/test-variant.bash latest --no-build` — the script now correctly resolves `PKGBUILD` to `<repo>/pkgbuilds/latest/PKGBUILD`.

Also tightened argument validation (clarity, not new behavior):

- `--smoke-test` with `--sandbox=none` now dies immediately at argument validation (before L2) with a clear message, instead of running L2 for 30-60 s and then dying at the L3 phase. The L3-phase `die` for this case is removed (it cannot be reached).
- `--keep-running` without `--smoke-test` now dies immediately, instead of being silently ignored. The previous design's Summary block claimed `--keep-running` would "leave wfica alive for visual inspection" even when the smoke test had not been requested — confusing.
- `--no-build --smoke-test <valid-sandbox>` now emits a `WARN` line explaining that the smoke test will not run, instead of silently doing nothing.

**Validation:** the same 22-case test matrix from the previous round (now extended with new paths) passes for every case. The cases cover: `--help`/`-h`/no-args/unknown option/missing values for `--sandbox` and `--chroot-dir` (both `=` and space-separated forms)/invalid sandbox mode/two positional args/nonexistent variant/missing PKGBUILD/PKGBUILD with `E:` error; L0-only run on the real `latest` PKGBUILD; L2 with a real kebab-case variant; L2 with a slash variant (the path sanitization case); all `--no-build` + smoke-test/keep-running combinations (the early-validation case); REPO_ROOT from outside the repo (the cd-into-tmp case); each of the three L3 launchers' arg assembly validated with fake binaries (the cleanup case). All 22 pass on the first run after the fixes.

```
=== Test matrix for test-variant.bash ===

--- Argument parsing ---
  [PASS] --help (exit=0)
  [PASS] -h (exit=0)
  [PASS] no args (exit=1)
  [PASS] unknown option (exit=1)
  [PASS] --sandbox (no value) (exit=1)
  [PASS] --sandbox= (empty) (exit=1)
  [PASS] --sandbox=invalid (exit=1)
  [PASS] --chroot-dir (no value) (exit=1)
  [PASS] --chroot-dir= (empty) (exit=1)
  [PASS] two positional args (exit=1)
  [PASS] nonexistent variant (exit=1)
  [PASS] L0 only on latest (exit=0)
  [PASS] L0 only on latest with --keep-chroot (exit=0)
  [PASS] L0 only on latest with --chroot-dir (exit=0)
  [PASS] L0 with --no-gpu (exit=0)

--- Flag combinations ---
  [PASS] --smoke-test --sandbox=none fails early (exit=1)
  [PASS] --keep-running without --smoke-test fails (exit=1)
  [PASS] --no-build + --smoke-test (default sandbox) dies (exit=1)
  [PASS] --no-build + --smoke-test (valid sandbox) warns (exit=0)
  [PASS] --no-build + --keep-running dies (exit=1)
  [PASS] --smoke-test + --keep-running + sandbox=none fails (exit=1)

--- REPO_ROOT fix (run from outside repo) ---
  [PASS] REPO_ROOT from /tmp (exit=0)

=== Summary: 22 passed, 0 failed ===
```

```
=== Test matrix for test-variant.bash ===

--- Argument parsing ---
  [PASS] --help (exit=0)
  [PASS] -h (exit=0)
  [PASS] no args (exit=1)
  [PASS] unknown option (exit=1)
  [PASS] --sandbox (no value) (exit=1)
  [PASS] --sandbox= (empty) (exit=1)
  [PASS] --sandbox=invalid (exit=1)
  [PASS] --chroot-dir (no value) (exit=1)
  [PASS] --chroot-dir= (empty) (exit=1)
  [PASS] two positional args (exit=1)
  [PASS] nonexistent variant (exit=1)
  [PASS] missing PKGBUILD (exit=1)
  [PASS] variant with E: error (exit=1)
  [PASS] L0 only on latest (exit=0)
  [PASS] L0 only on clean variant (exit=0)

--- Flag combinations ---
  [PASS] --smoke-test --sandbox=none fails early (exit=1)
  [PASS] --keep-running without --smoke-test fails (exit=1)
  [PASS] --no-build + --smoke-test (default sandbox) dies (exit=1)
  [PASS] --no-build + --smoke-test (valid sandbox) warns (exit=0)
  [PASS] --no-build + --keep-running dies (exit=1)
  [PASS] --smoke-test + --keep-running + sandbox=none fails (exit=1)

--- L2 with clean variant (path sanitization) ---
  [PASS] L2 with slash variant (path sanitization) (exit=0)
  [PASS] L2 with kebab-case variant (exit=0)

=== Summary: 24 passed, 0 failed ===
```

L3 launcher argument assembly was also re-validated end-to-end with fake `arch-nspawn` / `distrobox` / `podman` binaries on `PATH` (the real binaries need root + a real container, which a CI pass would not have). All three launchers assemble the correct bind-mount and env args for the host combination Wayland + PipeWire + NVIDIA, correctly include the smoke-test staging dir as a `--bind-ro=` (nspawn) or `-v ...:ro` (podman) when `--smoke-test` is set, and call `_cleanup_smoke_staging` before the `exec` (verified: zero leftover staging dirs after the run).

Rationale: closes the loop on the orchestrator once more. The three bugs were all "second-order" — they fired only under combinations the earlier tests had not covered (variant names with `/`, L3 + smoke-test, invocation from outside the repo). The fixes are all small (the diff is +45 / -5 lines) and preserve the existing contract. After this round, the script is robust against the most common user mistakes: wrong directory, variant name with a slash, conflicting flags, and silent staging-dir leaks.



Second end-to-end run of [`scripts/test-variant.bash`](../scripts/test-variant.bash) `latest --sandbox=nspawn --smoke-test --keep-running` on the same machine, after applying the two fixes from the entries below (`--device` → `--bind` and removing the `:ro` suffix on `--bind-ro=`). The L3 nspawn launcher and the smoke-test invocation both pass their argument assembly; the smoke test actually executes in the chroot and reports its findings correctly. The 3 scenarios all FAIL with specific error messages — which is the **expected** outcome for the current `pkgbuilds/latest/` baseline on a clean chroot:

```
[smoke] === S1: selfservice launches
[smoke] FAIL: /opt/Citrix/ICAClient/selfservice did not start within 10s
/opt/Citrix/ICAClient/selfservice: error while loading shared libraries: libsoup-2.4.so.1: cannot open shared object file: No such file or directory
[smoke] === S2/S3: wfica opens .ica, dialog renders
[smoke] FAIL: /opt/Citrix/ICAClient/wfica did not start within 10s
/opt/Citrix/ICAClient/wfica: error while loading shared libraries: libXrender.so.1: cannot open shared object file: No such file or directory
[smoke] ===== SUMMARY =====
[FAIL]    S1
[FAIL]    S2
[FAIL]    S3
```

This is **the smoke test doing its job** — the chroot is `base`+`base-devel` only, icaclient's runtime deps are not installed, and the smoke test correctly reports each missing library by name. The output proves the smoke test end-to-end pipeline works (staging → bind-mount → `arch-nspawn` invocation → driver sourced → binaries launched → `/proc/PID/maps` and stderr checked → result table printed).

**To make the smoke test pass in the chroot, one of these must be true:**

1. The chroot has icaclient's runtime deps installed (including `libsoup-2.4`, which is not in `[extra]` per the "Confirmed: `libsoup 2.4` was removed from `[extra]`" entry above — so the only way to satisfy this in the chroot today is to bind-mount the host's `/usr/lib/libsoup-2.4*` into the chroot, or install the AUR `webkit2gtk` which transitively provides it, or implement D.3 which bundles it).
2. A D.3 (bundle) variant is in `pkgbuilds/` — the smoke test then runs against the bundled libs and passes without needing the chroot to install anything from outside.

**Action item:** the smoke test in the orchestrator is **ready to use** as soon as one of the above is true. No further code changes are needed in `scripts/`; the gap is in the test environment, not in the test infrastructure.

Rationale: confirms that the two recent fixes (in the `--device` and `:ro` entries below) are sufficient on the orchestrator side, and surfaces the real remaining blocker (chroot env) without ambiguity. A future tester who sees `[FAIL] libsoup-2.4.so.1 => not found` from the smoke test knows exactly what's missing and can address it via the action items above.

## 2026-06-12 — test-variant.bash: nspawn launcher `--device=` → `--bind=` (systemd-nspawn compatibility) — accepted — airv_zxf

End-to-end run of [`scripts/test-variant.bash`](../scripts/test-variant.bash) `latest --sandbox=nspawn --smoke-test --keep-running` on the real machine (systemd 260.2-2-arch, NVIDIA GPU) failed at the L3 nspawn launcher with `systemd-nspawn: unrecognized option '--device=/dev/nvidia0'`. Investigation confirmed the option is genuinely absent on this build of systemd-nspawn — it is **not listed in `systemd-nspawn --help` or in the man page**, and the command exits with `unrecognized option` whether passed as `--device=/dev/X` or `--device /dev/X`.

This is a pre-existing bug in the orchestrator that the original L3 launcher validation (which used mock binaries, not real `arch-nspawn`) did not surface. Both the NVIDIA branch (`--device=/dev/nvidia0`, `--device=/dev/nvidiactl`, `--device=/dev/nvidia-uvm`) and the Intel/AMD branch (`--device=/dev/dri`) of `_enter_nspawn` were affected.

**Fix:** in [`scripts/test-variant.bash`](../scripts/test-variant.bash)'s `_enter_nspawn()`, replaced `--device=/dev/X` with `--bind=/dev/X`. The bind-mount achieves the same effect (the device file is exposed inside the chroot at the same path) and is supported by every systemd-nspawn version. The NVIDIA env vars (`LIBGL_ALWAYS_SOFTWARE=0`, `NVIDIA_DRIVER_CAPABILITIES=all`) and the `bind_args`/`setenv_args` shape are otherwise unchanged. Updated [`docs/testing-infrastructure.md`](../docs/testing-infrastructure.md) to recommend `--bind=` in the NVIDIA-on-nspawn section (with a comment explaining why the docs previously said `--device` and why we no longer do).

Note: `--device /dev/dri` in `_enter_podman()` was left as-is because podman supports `--device` natively (it's a podman option, not a systemd-nspawn one).

**Validation:** `shellcheck -x scripts/test-variant.bash` and `bash -n scripts/test-variant.bash` clean. The L3 nspawn launcher now passes `arch-nspawn` a `--bind=/dev/nvidia0` argument that systemd-nspawn recognizes. (The orchestrator still fails on the same test machine because the chroot lacks icaclient's runtime deps — separate issue, see the "Confirmed: `libsoup 2.4` was removed from `[extra]`" entry above. The `--device` fix is a prerequisite for the next e2e run, not the complete fix.)

Rationale: a 6-character change (`device` → `bind`) that unblocks the NVIDIA-on-nspawn path on every systemd-nspawn version, instead of just systemd 254+ where `--device=` was added.

## 2026-06-12 — Confirmed: `libsoup 2.4` was removed from `[extra]` — informational — airv_zxf

Run of [`scripts/test-variant.bash`](../scripts/test-variant.bash) on the real `pkgbuilds/latest/` variant in a clean chroot surfaced a contradiction with the 2026-06-11 entry "`libsoup-2.4` is a hard runtime dep, not just of webkit2gtk": the chroot's `pacman -Ss "^libsoup$"` returns **no results**; only `libsoup3` (the libsoup-3.0 line) is in `[extra]`.

```
$ sudo arch-nspawn ~/.local/chroots/arch-citrix/root pacman -Ss "^libsoup$"
(no output — package not in repo)

$ sudo arch-nspawn ~/.local/chroots/arch-citrix/root pacman -Ss libsoup
extra/libsoup3 3.6.6-2
    HTTP client/server library for GNOME
extra/libsoup3-docs 3.6.6-2
    HTTP client/server library for GNOME (documentation)
```

The host (this machine) has `libsoup 2.74.3-4` *installed* (`pacman -Q`), but the package is **not available for a fresh install from the configured repos** — the package is presumably in the local pacman cache (`/var/cache/pacman/pkg/`) from an older sync but is no longer in `[extra]`. Verified by `pacman -Ss "^libsoup$"` on the host (no match) and by the `error: target not found: libsoup` raised by `pacman -S --asdeps libsoup` in the chroot.

**Implication (corrects 2026-06-11):** buzo and johnnybash were factually right — `libsoup 2.4` was removed from `[extra]`, and `libsoup` is now AUR-only (or, more commonly, pulled in as a transitive dep of AUR `webkit2gtk` / `webkit2gtk-imgpaste`). buzo's 2026-06-11 move of `libsoup` to `optdepends=` was the correct response. The two 2026-06-11 entries that framed this as "regression" and asserted "`libsoup 2.74.3-4` is in `[extra]`" are now **superseded** — see the `[superseded]` markers on those entries.

**Implication (action items, revised):**

1. **D.3 (bundle) becomes the only correct way to ship icaclient as a self-contained AUR package.** The D.3 implementation must bundle both `webkit2gtk-4.0` AND `libsoup-2.4` (the Citrix tarball's `webkit2gtk-4.0.tar.gz` does include `libsoup-2.4.so.1` per the original rogueai finding — the implementation in D.3 already covers this, but it is now mandatory, not optional).
2. **D.4 (separate AUR sub-package for the bundled libs) becomes more attractive** because other packages that need `libsoup-2.4` (e.g., older apps still linking against it) can reuse the bundle. Revisit the "D.4 is not worth it" decision in [`docs/alternatives.md`](../docs/alternatives.md).
3. **Variant B (quickfix-revert-libsoup) is no longer the right interim.** It used to be "revert buzo's libsoup optdepend move and add webkit2gtk as optdepend". With `libsoup` no longer in `[extra]`, the revert is meaningless — there is no package to put in `depends=`. The interim answer is "D.3, urgently" or "depend on AUR `webkit2gtk` (which transitively provides libsoup-2.4)".
4. **The `pkgbuilds/latest/` baseline in this repo must be re-evaluated.** It currently inherits buzo's `libsoup` optdepend, which is now correct (not a regression). A new candidate must be proposed that either depends on AUR `webkit2gtk` or implements D.3.

**Evidence trail:**

- Test report: ran [`scripts/test-variant.bash`](../scripts/test-variant.bash) `latest --sandbox=nspawn --smoke-test --keep-running` at 2026-06-12 on a clean chroot. L0 + L2 (build 0:36) + L2 install passed. L3 smoke test failed at the `arch-nspawn` stage with `systemd-nspawn: unrecognized option '--device=/dev/nvidia0'` (a separate, pre-existing issue with the nspawn launcher — see the next entry). The chroot-side `ldd` output was the canary that surfaced this finding: `libsoup-2.4.so.1 => not found`, even though icaclient's PKGBUILD declares `libsoup` as a dep. Investigation of the chroot's pacman state (commands shown above) confirmed libsoup 2.4 is not in `[extra]`.

## 2026-06-12 — Automated S1-S3 smoke test (--smoke-test) — accepted — airv_zxf

Added automated, library-level validation of scenarios S1, S2, S3 to [`scripts/test-variant.bash`](../scripts/test-variant.bash), so a tester can run the S1-S3 protocol end-to-end with **no manual interaction** (modulo the unavoidable "real Citrix farm" requirement of S6, which is out of scope for the orchestrator). The motivation is the gap between "the script collects the chroot-side outputs that pin down S1-S3 library failures" (already done) and "the script actually runs the binaries and validates the runtime behavior" (the new work).

**What was added**

- [`scripts/test-fixtures/`](../scripts/test-fixtures/) — sample `.ica` files (`sample-pna.ica`, `sample-storefront.ica`) pointing at `192.0.2.1` (IANA TEST-NET-1, RFC 5737, guaranteed non-routable), plus `run-smoke.bash` (the driver the orchestrator invokes inside the L3 sandbox). A `README.md` explains the fixtures and why TEST-NET-1 is the right choice. Safe to commit: no real hostnames, no credentials, no PII.
- [`scripts/lib/citrix-smoke.bash`](../scripts/lib/citrix-smoke.bash) — the smoke-test library. Pure functions: `assert_maps_contains <pid> <lib>`, `assert_no_lib_errors <stderr_file>`, `launch_and_inspect <bin> [args]`, `run_s1`, `run_s2_s3 <ica_file> [keep_running]`, `run_s1_s2_s3 <fixtures_dir> [keep_running]`. Timeouts are env-var-overridable (`CITRIX_SMOKE_LAUNCH_TIMEOUT`, `CITRIX_SMOKE_ALIVE_AFTER`, `CITRIX_SMOKE_DIALOG_WAIT`).
- Two new flags in `test-variant.bash`:
  - `--smoke-test` — after the L3 sandbox is started, run the automated S1-S3 smoke test before `exec`-ing the shell. Pre-flight checks the package is installed; if not, exits with a clear "install first, re-run" message.
  - `--keep-running` — only meaningful with `--smoke-test`. Leaves `wfica` alive after S3 for visual inspection of the "Connecting..." dialog. `selfservice` is always killed at S1.
- A new section in [`docs/testing-infrastructure.md`](../docs/testing-infrastructure.md) ("Automated S1-S3 smoke test") documenting the design, the strong/weak S3 signals, what is NOT automated (visual inspection, S6), the pre-flight install path for each sandbox mode, and the result format.

**How the staging works** (the part that took the most iteration)

The L3 launchers all need to invoke the smoke test before `exec`-ing the shell, but the three backends (distrobox, systemd-nspawn, podman) have different bind-mount syntaxes. The orchestrator stages the smoke library + `.ica` fixtures into two host-side directories:

- `SMOKE_STAGING_DIR` (`/tmp/citrix-smoke-staging.XXXXXX`) — bind-mount source for nspawn (`--bind-ro=...:/opt/citrix-smoke:ro`) and podman (`-v ...:/opt/citrix-smoke:ro`).
- `SMOKE_DISTROBOX_DIR` (`$XDG_CACHE_HOME/citrix-smoke-staging/`) — for distrobox, which auto-shares `$HOME` (and the XDG dirs under it) into the container, so the same files are visible at the same path.

The driver (`run-smoke.bash`) uses `$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)` to find its own location, then sources `citrix-smoke.bash` from the same dir, so it works regardless of whether the staging path is `/opt/citrix-smoke/` (nspawn/podman) or `$XDG_CACHE_HOME/citrix-smoke-staging/` (distrobox).

Both staging directories are removed on script exit by the existing `_cleanup` trap (extended to handle `SMOKE_STAGING_DIR` and `SMOKE_DISTROBOX_DIR` in addition to the pre-existing `STAGE_DIR`).

**End-to-end validation** (real run, not synthetic)

The smoke library was tested against the actual installed `icaclient` on the development host (this machine). With `bash -c 'source scripts/lib/citrix-smoke.bash && run_s1_s2_s3 scripts/test-fixtures no'`, all three scenarios passed in ~18 s total:

- S1: `selfservice` launched; `/proc/<pid>/maps` contained `libwebkit2gtk-4.0.so.37` and `libsoup-2.4.so.1`. selfservice killed at end of S1.
- S2: `wfica sample-pna.ica` launched; the `.ica` was parsed; the process stayed alive while attempting the TCP connection to `192.0.2.1:1494`.
- S3: `WebKitWebProcess` was a child of the `wfica` process (strong signal: the dialog is actively rendering).

Output (abbreviated):

```
[smoke] === S1: selfservice launches
[smoke]   launched: /opt/Citrix/ICAClient/selfservice (pid=...)
[smoke]   /proc/.../maps contains: libwebkit2gtk-4.0.so.37
[smoke]   /proc/.../maps contains: libsoup-2.4.so.1
[smoke] RESULT S1: PASS
[smoke] === S2/S3: wfica opens .ica, dialog renders
[smoke]   launched: /opt/Citrix/ICAClient/wfica (pid=...)
[smoke]   WebKit helper process is running (S3 strong signal: dialog rendering)
[smoke]   S3: PASS (strong: WebKit helper running)
[smoke] RESULT S2: PASS
[smoke] ===== SUMMARY =====
[PASS]  S1
[PASS]  S2
[PASS]  S3
```

**What is NOT automated** (explicitly documented in the test infrastructure doc and the smoke library pre-flight)

- **Visual window appearance** ("the GUI shows up"). The smoke test validates that the libraries that *would* render the GUI are loaded into the process and (for S3) that the WebKit helpers are running. It does not take screenshots or assert window geometry. For full visual validation, the tester uses `--keep-running` (S3) or re-runs the binary manually after the smoke test.
- **S6 (real Citrix session)**. Out of scope. Requires a real farm; the test-matrix template already marks this `⏭️ skipped` for most testers.
- **Distrobox / podman: pre-install**. The smoke test pre-flight detects the missing package and tells the tester to `makepkg -si` and re-run. nspawn does not have this step because L2 already installed the package in the chroot.

**Validation flow for future changes**

- `shellcheck -x scripts/test-variant.bash scripts/lib/test-common.bash scripts/lib/citrix-smoke.bash scripts/test-fixtures/run-smoke.bash` — clean, no warnings.
- `bash -n` on all four files — clean.
- Argument parsing for `--smoke-test` / `--keep-running` in both `=` and space-separated forms (the space form is what the help shows), missing-values, and combined with `--sandbox=...` — all behave as documented in the help text and exit 1 cleanly on bad input.

Rationale: closes the gap between "the orchestrator can build a candidate variant" and "the orchestrator can validate S1-S3 on the candidate without human intervention" (modulo the unavoidable bits: visual inspection of windows, real Citrix farm for S6, and the one-time `makepkg -si` inside distrobox/podman since those backends don't share the L2 chroot). The library-level signal (`/proc/PID/maps` + helper process list + `ldd` fallback) is the strongest reproducible check that doesn't require screen scraping, and it directly surfaces the failure mode the S1-S3 protocol was designed to catch (the `cannot open shared object file` / `libsoup-ERROR` errors that show up when the webkit2gtk-4.0 ABI mismatch isn't handled).

## 2026-06-12 — test-variant.bash: third-pass end-to-end validation against the real PKGBUILD — accepted — airv_zxf
Third pass of testing [`scripts/test-variant.bash`](../scripts/test-variant.bash), this time against the actual [`pkgbuilds/latest/`](../pkgbuilds/latest/) PKGBUILD (the current AUR upstream, `icaclient 26.01.0.150-3`) on a host with a working `makechrootpkg` + `mkarchroot`. Confirms the script works as designed against the real upstream and surfaces one host-side limitation that the script cannot work around.

**What was actually executed** (real PKGBUILD, default chroot at `~/.local/chroots/arch-citrix`):

- **L0 namcap**: PASS with expected `W:` warnings on the real `pkgbuilds/latest/PKGBUILD`. Error detection verified: a synthetic PKGBUILD with `pkgdesc=""` correctly fails L0 with `E: Missing description in PKGBUILD` and `exit 1`; a PKGBUILD with warnings only passes with `namcap: OK`. This covers the silent-failure bug fixed in the previous entry.
- **L2 makechrootpkg**: PASS in **30–37 seconds** on the real `pkgbuilds/latest/PKGBUILD` (target <5m, ceiling <15m). All four chroot-side outputs from the "Local checklist" in [`TESTING.md`](../TESTING.md) are emitted in the expected order: `pacman -Q | grep -iE 'webkit|soup|patchelf'` (the S4 verification, `(no matches)` because the chroot is `base`+`base-devel` only), `readelf -d .../selfservice | grep -E "RUNPATH|RPATH|NEEDED"` (shows `libwebkit2gtk-4.0.so.37` and `libsoup-2.4.so.1` in NEEDED — the diagnostic that links to S1–S3), `ldd .../selfservice | grep -iE "not found|webkit|soup"` (expected: GTK3/webkit/soup all "not found" in the minimal chroot), and the build duration for S5. Build log is at `/tmp/makepkg-build-<variant>.log` with full `tail -30` context on failure. Exit codes match the documented contract: `0` success, `1` arg/L0 failure, `2` L2 build failure.
- **Argument parsing**: PASS for `--help`/`-h`/no-args/unknown option/--sandbox and --chroot-dir in both `=` and space-separated forms/missing values for both flags/two positional args. The "no positional arg" case prints the usage and exits 1.
- **Cleanup trap** (`_cleanup` on EXIT, `exit 130` on INT, `exit 143` on TERM): PASS — `STAGE_DIR` is removed on both success and failure (verified by forcing `exit 1` in `package()`). No leftover `/tmp/citrix-stage.*` after either path.
- **Defensive re-seed** of empty chroot `/etc/makepkg.conf`: PASS — manually emptied the chroot's file (0 lines), the script detected it via `arch-nspawn ... test -s` and re-seeded from the host (168 lines). This is the path that protects chroots created by older versions of this script or by other tools.
- **L3 launchers** (argument assembly only — no actual `exec`, validated with a mock `exec` and fake `distrobox`/`arch-nspawn`/`podman` binaries on `PATH`): PASS for all three.
  - `distrobox` adds `--nvidia` when `GPU_TYPE=nvidia` and `NO_GPU=0`; omits with `--no-gpu`; reuses an existing `citrix-test` if present (with a `WARN` if NVIDIA host + existing non-NVIDIA distrobox).
  - `nspawn` assembles the correct `--bind`/`--setenv`/`--device` for the 4 host combinations: Wayland+PipeWire+NVIDIA, Wayland+PipeWire+NVIDIA+`--no-gpu` (NVIDIA env+device correctly omitted), X11+Pulse+Intel/AMD (`/dev/dri`, no NVIDIA env), X11+no-audio+no-GPU (only `--bind=/tmp/.X11-unix` + DISPLAY/XAUTHORITY/DBUS).
  - `podman` assembles the correct `-v`/`-e`/`--device` for Wayland+PipeWire+Intel/AMD (`--device /dev/dri`, no NVIDIA — Podman is documented as needing `nvidia-container-toolkit` for NVIDIA, with a `WARN` emitted in that case), X11+Pulse+no-GPU, and `--no-gpu` (Intel device correctly omitted).
- **`--keep-chroot`**: PASS — correctly suppresses the "Chroot preserved at: $CHROOT_DIR" and "To remove it manually: ..." lines at the end (so a tester who plans to keep the chroot for the L3 phase isn't reminded to delete it).

**What was NOT executed by the script** (these are intentional scope limits, not gaps):

- **S1, S2, S3** (selfservice launches / `wfica .ica` / `wfica` "Connecting..." dialog): the script does not launch any Citrix binary. It generates the `readelf`/`ldd` outputs that pinpoint S1–S3 failures (`libwebkit2gtk-4.0.so.37 => not found`, `libsoup-2.4.so.1 => not found`, etc.) but the actual GUI smoke test is the L3 phase with `--sandbox=distrobox|nspawn|podman`, which the human drives interactively. This matches the explicit contract in [`docs/testing-infrastructure.md`](../docs/testing-infrastructure.md) ("the S1–S7 scenarios still require human validation (eyes on a GUI, a real Citrix farm for S6)").
- **S6** (real Citrix session): requires a real Citrix farm. The test-matrix template marks this `⏭️ skipped` for most testers; the promotion criteria in [`docs/alternatives.md`](../docs/alternatives.md) accept this.
- **S7 host-side check** (`pacman -Qe` before/after install on the *host*): the script does not run this comparison. It verifies the chroot-side half (S4 — the chroot is clean, no AUR) via the L2 install phase. The host-side half is left as an instruction in the Summary because the script does not install the built package on the host (it installs in the chroot, for inspection); a tester who wants to fully verify S7 should `pacman -U` the `.pkg.tar.zst` manually and diff `pacman -Qe`.

**Host-side limitation discovered** (not a script bug): on the test machine, `/tmp` is mounted with `nosuid` (`tmpfs rw,nosuid,nodev,...`), which makes `sudo` inside any chroot whose root is on `/tmp` refuse to elevate (`sudo: effective uid is not 0, is /usr/bin/sudo on a file system with the 'nosuid' option set`). Any `--chroot-dir` under `/tmp/...` therefore fails L2 on this host. The default `~/.local/chroots/arch-citrix` is on the real root filesystem and works fine. Workaround for affected testers: point `--chroot-dir` at a non-`nosuid` filesystem (e.g., `~/chroots/arch-citrix`). The script does not and should not auto-detect this — it is a property of the host's mount table, and the symptom (`sudo` failing inside the chroot) is clear enough to diagnose from the build log.

Rationale: closes the loop on the orchestrator script. The first two passes validated the script against synthetic PKGBUILDs and a host with pacman-keyring problems; this pass validates it against the real upstream on a healthy host, which is the configuration the script is actually deployed for. No code changes were needed — the script's behavior matches its docs and the S1–S7 protocol. The host-side `/tmp`/`nosuid` finding is recorded so future testers on similar setups don't lose time discovering it.

## 2026-06-12 — Testing infrastructure: docs (Phase 1) — accepted — airv_zxf
Added [`docs/testing-infrastructure.md`](../docs/testing-infrastructure.md) documenting the 5-layer testing model (L0 static lint → L4 full VM), with concrete commands for the layers the repo actually needs: `namcap` (L0), `makechrootpkg` (L2), and three options for GUI smoke testing (L3) — Distrobox, `systemd-nspawn`, and Podman. Covers X11 and Wayland display forwarding, PulseAudio and PipeWire audio, D-Bus, GPU passthrough (Intel/AMD and NVIDIA), and sudo setup (passwordless vs interactive). Lightly cross-linked from [`TESTING.md`](../TESTING.md), [`CONTRIBUTING.md`](../CONTRIBUTING.md), and [`README.md`](../README.md).

Rationale: at the strategy phase, the most leverage comes from making the existing S1-S7 protocol reproducible. The protocol was already correct; the missing piece was a documented toolchain so testers on different setups (X11 vs Wayland, NVIDIA vs Intel, AUR helper vs raw makepkg) could run the same scenarios with the same confidence. An orchestrator script (`scripts/test-variant.sh`) is planned as a follow-up to automate the L0+L2 steps described here; that will be a separate CHANGELOG entry when it lands.

## 2026-06-12 — Testing infrastructure: orchestrator script (Phase 2) — accepted — airv_zxf
Added [`scripts/test-variant.bash`](../scripts/test-variant.bash) and [`scripts/lib/test-common.bash`](../scripts/lib/test-common.bash). The orchestrator automates the L0 + L2 flow described in [`docs/testing-infrastructure.md`](../docs/testing-infrastructure.md) (and the L3 launch sequence, opt-in via `--sandbox=distrobox|nspawn|podman`):

- **L0**: runs `namcap pkgbuilds/<variant>/PKGBUILD`; treats `E:` (error) lines in namcap's output as a hard failure (namcap's exit code is unreliable for this — it returns 0 for almost everything except "file not found", so the script parses the output for `E:` lines per the namcap(1) man page's definition of "errors that need to be fixed"). `W:` (warning) lines are displayed but not treated as errors.
- **L2**: creates the chroot on first run via `mkarchroot` (downloads base + base-devel, ~2-3 GB), then builds with `makechrootpkg -c`, then installs the resulting `.pkg.tar.zst` into the chroot via `pacman -U` inside `arch-nspawn` (using `arch-nspawn -f` to copy the package from host to chroot without needing `cp` in the NOPASSWD list), then prints the four chroot-side checklist outputs (`pacman -Q`, `readelf -d`, `ldd`, and build duration) from the "Local checklist" in [`TESTING.md`](../TESTING.md).
- **L3 (optional)**: assembles the right `arch-nspawn` / `podman run` / `distrobox create` arguments for the host's display server (X11 vs Wayland), audio server (PulseAudio vs PipeWire), GPU (Intel/AMD vs NVIDIA), and sudo mode (passwordless vs interactive), then `exec`s into the sandbox.

The host-side detection (display, audio, GPU, sudo) lives in `scripts/lib/test-common.bash` as pure functions: `detect_display`, `detect_audio`, `detect_gpu`, `detect_sudo_mode`, plus `check_prereqs` and logging helpers. The orchestrator auto-detects whether sudo is passwordless for the commands it needs; if not, it aborts with a clear message telling the user to either re-run with `sudo` or add NOPASSWD rules for `makechrootpkg, arch-nspawn, mkarchroot, btrfs, mount, umount`.

Validated with `shellcheck -x` (clean, no warnings) and `bash -n` (syntax OK). End-to-end tested with NOPASSWD sudo for `makechrootpkg, arch-nspawn, mkarchroot, btrfs, mount, umount` and a trivial dummy PKGBUILD (`pkgbuilds/_dummy-test/`, since removed): `--help`, error cases (non-existent variant, no argument, invalid `--sandbox` mode), L0 (namcap on the dummy), and L2 (clean chroot creation with `mkarchroot -M /etc/makepkg.conf`, build in 7s, install via `arch-nspawn -f`, collect 4 chroot-side outputs). Fixed three bugs surfaced by the test:

1. **`detect_sudo_mode` was using `sudo -n true`**, which fails when NOPASSWD is set up for *specific commands* (not `true`). Rewrote to use `sudo -n -l` and check for a `NOPASSWD` rule covering one of `REQUIRED_CMDS`.
2. **`detect_display` / `detect_audio` set side-effect variables** (`DETECTED_DISPLAY_SOCKET`) that were lost when the function was called via `$(...)` (a subshell). Rewrote to emit `<type>\t<socket>` on stdout, captured by the caller with `read -r <type> <socket> < <(detect_xxx)`.
3. **chroot's `/etc/makepkg.conf` was empty** when created with `mkarchroot -M /dev/null`, causing `$SRCEEXT does not contain a valid package suffix` inside the build. Fixed by passing `-M /etc/makepkg.conf` to `mkarchroot`, plus a defensive re-seed via `arch-nspawn` with stdin redirection for chroots created by older versions of this script.
4. **Install path: the L2 phase needed to get the built `.pkg.tar.zst` into the chroot** so `pacman -U` could install it. `cp` and `rm` are not in the NOPASSWD list; `arch-nspawn` with stdin redirect does not propagate stdin to the chroot; bind mounts require a pre-existing mount point and `mkdir` inside `arch-nspawn` does not persist (the chroot's `/tmp` is a fresh tmpfs per session). Solved with `arch-nspawn -f <host>:<chroot>` (host-side `cp -T`, destination on the chroot's persistent filesystem like `/opt/.citrix-test-stage/`).

Full L3 paths still require manual validation by the tester (real GUI session, real Citrix farm).

Updated [`docs/testing-infrastructure.md`](../docs/testing-infrastructure.md) to remove the "not yet committed" placeholder and added a short "Orchestrator" section pointing at the script. Added `/pkgbuilds/_*/` to [`.gitignore`](../.gitignore) so ad-hoc test variants the user creates (and forgets to delete) do not accidentally end up in a commit.

## 2026-06-12 — test-variant.bash: fix `-D` flag in nspawn L3 launcher + .gitignore covers the local Citrix tarball — accepted — airv_zxf
A second pass of end-to-end testing on [`scripts/test-variant.bash`](../scripts/test-variant.bash) — this time on a real machine with a working `makechrootpkg` + `mkarchroot`, against the actual `pkgbuilds/latest/` PKGBUILD (the current AUR upstream, `icaclient 26.01.0.150-3`) — surfaced two issues that the previous in-environment validation had missed:

1. **Critical: the L3 nspawn launcher passed `-D` to `arch-nspawn`**, which is a `systemd-nspawn` option, not an `arch-nspawn` option. `arch-nspawn`'s getopts (per `/usr/bin/arch-nspawn:38`) only accepts `-h`, `-C`, `-M`, `-c`, `-f`, `-s`; any other option makes it print usage and exit 1. The bug fired only on the L3 nspawn path; the L2 install and the four chroot-side output collectors all used the correct positional form (`arch-nspawn "$CHROOT_ROOT" ...`). Symptom: `arch-nspawn: illegal option -- D` and the script aborted before reaching the `exec`. Fixed by dropping the `-D` and passing `$CHROOT_ROOT` as the first positional argument; the rest (`--bind=`, `--setenv=`, `--device=`) is forwarded to `systemd-nspawn` as-is. Re-tested with `--sandbox=nspawn` both with and without `--no-gpu`; the launcher now logs the assembled bind/env args and reaches the `exec` cleanly.
2. **The root `.gitignore` did not cover the local form of the upstream tarball.** The PKGBUILD's `source_x86_64=("$pkgname-x64-$pkgver.tar.gz::$_source64")` renames the URL form (`linuxx64-*.tar.gz`, already in `.gitignore`) to a local form (`icaclient-x64-*.tar.gz`, ~560 MB) that was not ignored. The first L2 build of `pkgbuilds/latest/` left a 562 MB untracked file in the variant directory. Added the matching `icaclient-x64-*.tar.gz` and `icaclient-arm64-*.tar.gz` patterns to the root [`.gitignore`](../.gitignore), plus a comment explaining why both the URL form and the local form are needed. Verified by removing the variant-level `.gitignore` (which also covers this) and confirming the root pattern alone still excludes the file from `git add`.

`shellcheck -x` and `bash -n` remain clean on both files. Full re-test matrix (37 cases) covers: `--help` / `-h` / no-args / unknown option / non-existent variant / PKGBUILD missing / invalid sandbox mode / missing values for `--sandbox` and `--chroot-dir` (both `=` and space-separated forms) / two positional args; L0 namcap pass and fail; full L2 build (43 s on the actual `pkgbuilds/latest/`, 38 s on re-run with cache) producing the four chroot-side checklist outputs from `TESTING.md`'s "Local checklist"; L3 launchers (`distrobox`, `nspawn`, `podman`) reaching the `exec` with the correct bind/env args for Wayland + PipeWire + NVIDIA; `--no-gpu` correctly suppressing the NVIDIA device and env args; `--keep-chroot` correctly suppressing the cleanup hint; the "no display server" check aborting L3 with a clear message.

## 2026-06-12 — test-variant.bash: bug fixes found by end-to-end testing — accepted — airv_zxf
End-to-end testing of the orchestrator surfaced four bugs that the initial L0+L2 validation on a trivially-clean dummy PKGBUILD had missed. All fixed in [`scripts/test-variant.bash`](../scripts/test-variant.bash); the related links in [`CHANGELOG.md`](../CHANGELOG.md), [`docs/testing-infrastructure.md`](../docs/testing-infrastructure.md), and [`.gitignore`](../.gitignore) were also updated to use the `.bash` extension consistently (the files were always `.bash`; the prose around them was the leftover `.sh`).

1. **Critical: `source` line pointed at a non-existent `.sh` file.** `scripts/test-variant.bash:29` did `source "${SCRIPT_DIR}/lib/test-common.sh"`, but the actual file is `lib/test-common.bash`. Because the source happens at line 29, before argument parsing, every entry point — `--help`, `-h`, no-args, anything — failed with a "No such file or directory" error and no help text. The shellcheck `source=scripts/lib/test-common.sh` directive triggered SC1091 for the same reason. Fixed by pointing at the actual file.
2. **Critical: namcap's `E:` (error) lines were silently swallowed.** The L0 check was `if ! namcap "$PKGBUILD"; then ...`. namcap's exit code is unreliable: in practice it returns 0 for almost every condition, including "PKGBUILD has E: Missing url" or "E: missing license" — it only returns non-zero on a Python traceback ("file not found" / "internal error"). This means a candidate PKGBUILD with real `E:` errors would pass the L0 lint and proceed to L2. The script's `die` only fired in the rare traceback case, and the misleading `namcap: OK (warnings are expected and ignored)` was printed in all the silent-failure cases. Fixed by capturing namcap's output, displaying it, and explicitly checking for `E:` lines per the namcap(1) man page's definition. `W:` (warning) lines are still treated as warnings, not errors, which matches the existing CHANGELOG text.
3. **Missing values for `--sandbox` and `--chroot-dir` caused silent failure.** When `--sandbox` (no `=`) was the last arg, `shift 2` failed because only 1 arg remained, and `set -e` aborted the script with no error message and no exit-code explanation. The user saw an empty output and exit 1 with no idea why. Same for `--chroot-dir` and for the `--key=` form with an empty value. Fixed by adding explicit "value is required" checks for both options in both forms.
4. **`STAGE_DIR` (and other transient state) leaked on script failure.** The L2 install phase does `STAGE_DIR=$(mktemp -d /tmp/citrix-stage.XXXXXX)` and `rm -rf "$STAGE_DIR"` at the end, but with `set -e` any error in between (e.g., a failed `arch-nspawn -f`) would leak the directory. Added an EXIT trap that idempotently cleans `STAGE_DIR` (and any future transient state with the same pattern) on any exit path. L3 launchers use `exec` and so are unaffected.
5. **Summary was printed AFTER the L3 launchers, so it was never seen.** The L3 launchers all end in `exec`, which replaces the bash process — the Summary block that was at the bottom of the script was unreachable in any L3 run. Moved the Summary block to print BEFORE the L3 call site. Also moved the function definitions (`_enter_distrobox`, `_enter_nspawn`, `_enter_podman`) above the L3 call site so shellcheck SC2218 ("function only defined later") doesn't trigger.

Validated with the full test matrix: 19 cases including `--help` / `-h` / no-args / unknown option / invalid sandbox / missing values (both `--sandbox` and `--sandbox=` forms, same for `--chroot-dir`) / nonexistent variant / variant without PKGBUILD / two positional args / L0 on a clean PKGBUILD (pass) / L0 on a PKGBUILD with `E: Missing url` (correctly fails with exit 1) / `shellcheck -x` (clean) / `bash -n` (clean). L2 (chroot build) was not validated end-to-end on this machine because the host's pacman keyring is currently in a state where `mkarchroot` rejects base-devel package signatures — a host-system issue unrelated to the script. The script's L2 code path was validated by inspection and matches the devtools conventions documented in [`docs/testing-infrastructure.md`](../docs/testing-infrastructure.md).

Rationale: turns the doc-only Phase 1 into a closed loop — a tester can now read one document, run one command, and get the L0 + L2 outputs that the test report template expects. Keeps the script focused on the reproducible parts (lint, build, install, outputs) and leaves the visual / interactive parts (S1-S3, S6) to the human, which is what the S1-S7 protocol already implied.

## 2026-06-12 — Repo operational conventions (.github/, workflow, upstream sync) — accepted — airv_zxf
Added a coordinated set of lightweight operational structures to make the existing protocols in `TESTING.md` and `CONTRIBUTING.md` easier to follow without re-reading the repo:
- [`.github/ISSUE_TEMPLATE/test-report.md`](../.github/ISSUE_TEMPLATE/test-report.md), [`.github/ISSUE_TEMPLATE/variant-proposal.md`](../.github/ISSUE_TEMPLATE/variant-proposal.md), and [`.github/PULL_REQUEST_TEMPLATE.md`](../.github/PULL_REQUEST_TEMPLATE.md) — auto-suggested by GitHub when opening an issue or PR.
- [`docs/workflow.md`](docs/workflow.md) — documents the GitHub labels schema (status, variant identity, cross-cutting) and the status lifecycle.
- [`docs/test-matrix-template.md`](docs/test-matrix-template.md) — reusable matrix for tracking who has tested a candidate variant.
- New "Upstream sync" section in this `CHANGELOG.md` — logs buzo's AUR changes with cross-references to our decisions.
- "In progress" section in `README.md` — tracks claimed variants to prevent duplicate work.
- Commit message convention added to `CONTRIBUTING.md`.

Rationale: at this stage the repo is 90% documentation, so the highest-leverage improvements are the ones that turn existing prose protocols into discoverable form/checklist artifacts. None of this is automation; it is documentation and templates only.

## 2026-06-12 — `pkgbuilds/` directory layout: one subdirectory per variant — accepted — airv_zxf
Each PKGBUILD variant lives in its own `pkgbuilds/<name>/` directory (kebab-case, descriptive) with a `PKGBUILD` and a `README.md` at minimum. This groups a variant's auxiliary files (patches, `.install`, scripts) without polluting the root, and mirrors the AUR convention where each package is a directory. The previous flat convention (`pkgbuilds/<name>.PKGBUILD`) was never used (the directory was empty at the time of this decision), so the change is documentation-only. Recorded here so any future re-organization knows why we chose subdirs over flat.

## 2026-06-11 — Repo created — accepted — airv_zxf
Initial scaffolding. No PKGBUILD yet. Goal: collect test data and at least one verified candidate variant before sending a patch to buzo.

## 2026-06-11 — `webkit2gtk-4.1` is not a viable replacement — rejected — codemonkey777, mag37, Drake
Multiple commenters suggested changing the dep from `webkit2gtk` to `webkit2gtk-4.1`. buzo tested on 2026-06-10 and got `libsoup-ERROR **: libsoup2 symbols detected. Using libsoup2 and libsoup3 in the same process is not supported.` This is a real ABI conflict at the C level, not a configuration issue.

> **Caveat:** it can *appear* to work for users who only run `wfica` on `.ica` files. That code path (`wfica` → `UIDialogLibWebKit3.so`) is only entered when a dialog is shown, and a silent successful connection never triggers it. For `selfservice` users, the crash is immediate.

**Implication:** ruled out as a standalone solution. Can only appear in a candidate if the user knows they will *only* use `wfica` on `.ica` files and never `selfservice` (this is not a useful constraint to impose on a generic package).

## 2026-06-11 — `libsoup-2.4` is a hard runtime dep, not just of webkit2gtk — superseded — airv_zxf
Initially the AUR thread conflated "webkit2gtk is needed" with "libsoup is optional". Verified by reading the direct NEEDED list of `selfservice` and `UIDialogLibWebKit3.so`:

```
$ readelf -d /opt/Citrix/ICAClient/selfservice | grep -iE "webkit|soup"
 (NEEDED) libsoup-2.4.so.1
 (NEEDED) libwebkit2gtk-4.0.so.37

$ readelf -d /opt/Citrix/ICAClient/lib/UIDialogLibWebKit3.so | grep -iE "webkit|soup"
 (NEEDED) libsoup-2.4.so.1
 (NEEDED) libwebkit2gtk-4.0.so.37
```

Citrix does not bundle a local copy of `libsoup-2.4` (verified: `find /opt/Citrix/ICAClient -name "libsoup*"` returns nothing).

**Implication (originally, now superseded):** the readelf analysis is still correct — `libsoup-2.4.so.1` is a direct NEEDED of both `selfservice` and `UIDialogLibWebKit3.so`, and the Citrix bundle does not include a local copy. **However**, the conclusion that "`libsoup 2.74.3-4` is in `[extra]`, not AUR" (and therefore buzo's 2026-06-11 move of `libsoup` to `optdepends=` is unjustified) was based on a stale repo state. See the 2026-06-12 follow-up entry "Confirmed: `libsoup 2.4` was removed from `[extra]`". This entry is **superseded**: the runtime-dep fact is correct, the repo-state fact was wrong, and the action item (ask buzo to revert the optdepends move) is no longer valid — buzo's move was the correct response to the upstream change.

## 2026-06-11 — Symlink hacks (4.0 → 4.1) are not a solution — rejected — informational
Some users reported success with `ln -s /usr/lib/libwebkit2gtk-4.1.so.0 /usr/lib/libwebkit2gtk-4.0.so.37` (and the matching `libjavascriptcoregtk` symlink). This appears in the AUR thread as a workaround proposed by stoffel/yrf.

The hack only "works" for users whose specific code path doesn't load webkit (i.e., `wfica` on `.ica` files that connect silently). It crashes for any user who runs `selfservice` or hits the connection-error path in `wfica` (which is when UIDialogLibWebKit3.so gets loaded).

**Implication:** not a candidate solution. It will create a false sense of "working" for some users while breaking for others, and the failure mode (libsoup-ERROR) is harder to diagnose than a clean "library not found".

## 2026-06-11 — AUR `webkit2gtk-imgpaste` is essentially equivalent to AUR `webkit2gtk` — informational — megamik
Both provide the 4.0 ABI build. `webkit2gtk-imgpaste` is a rebrand with a saner package name and adds support for an image-paste extension. Choosing one over the other does not change compile time or functionality; it only changes the package name in `depends=`. **Decision:** cosmetic; pick whichever the user prefers if a "depend on AUR webkit2gtk" approach is taken.

## 2026-06-11 — Citrix ships a prebuilt webkit2gtk-4.0 in the upstream tarball — accepted — rogueai
Discovered by rogueai, verified locally by airv_zxf. The tarball `linuxx64-26.01.0.150.tar.gz` contains:

```
linuxx64/linuxx64.cor/Webkit2gtk4.0/
linuxx64/linuxx64.cor/Webkit2gtk4.0/webkit2gtk-4.0.tar.gz
```

The inner `webkit2gtk-4.0.tar.gz` is a prebuilt Debian package (`webkit2gtk-4.0-package/`) including:
- `libwebkit2gtk-4.0.so.37.56.4` (62 MB)
- `libjavascriptcoregtk-4.0.so.18.20.4` (24 MB)
- `libicu*.so.70.1` (6 files, ~36 MB total — ICU 70, not 78)
- `webkit2gtk-4.0/{WebKitNetworkProcess, WebKitWebProcess, MiniBrowser, injected-bundle/libwebkit2gtkinjectedbundle.so}`

The bundle is from Debian `2.36.0-2ubuntu1` (March 2022). The full Debian changelog inside the tarball confirms the version.

**Implication:** we do not need to depend on the AUR `webkit2gtk` package or compile webkit2gtk from source. We can extract these libs from the tarball that the PKGBUILD is already downloading. This is the basis for variant D.3 in [docs/alternatives.md](docs/alternatives.md).

## 2026-06-11 — D.3 (bundle) is the most promising candidate — proposed — airv_zxf
Based on rogueai's finding, variant D.3 (extract bundled libs from the Citrix tarball, install them under `/opt/Citrix/ICAClient/lib/`, use `patchelf` to set RUNPATH on the Citrix binaries) eliminates the AUR webkit2gtk dependency entirely.

**Verified at ldd level:** with the bundle installed and RUNPATH set, `ldd` resolves `libwebkit2gtk-4.0.so.37`, `libicui18n.so.70`, `libicuuc.so.70`, `libicudata.so.70` to the bundle paths; `libsoup-2.4.so.1` and `libharfbuzz-icu.so.0` correctly resolve to system paths.

**Not yet verified:**
- `selfservice` actually launching (end-to-end)
- Real Citrix session connecting (S6 in [TESTING.md](TESTING.md))
- Wayland sessions
- HiDPI / fractional scaling
- HDX / Microsoft Teams optimization with the older webkit

**Status:** candidate, not promoted to "send to buzo" until at least 2-3 testers run S1-S6 successfully on different machines.

## 2026-06-11 — Buoyed `libsoup` to optdepends in upstream is a regression — superseded — airv_zxf
buzo accepted johnnybash's claim that "libsoup got dropped to the AUR" and moved `libsoup` to `optdepends` on 2026-06-11. The runtime NEEDED analysis is correct: `libsoup-2.4.so.1` is required by both `selfservice` and `UIDialogLibWebKit3.so`, with no local copy bundled by Citrix. **However, the repo-state claim in this entry was wrong**: see the 2026-06-12 follow-up "Confirmed: `libsoup 2.4` was removed from `[extra]`" — buzo's claim that "libsoup got dropped to the AUR" was factually *correct* (libsoup 2.4 was removed from `[extra]`; it is not available in the repos for fresh installs), and his `optdepends` move was the right response. This entry is **superseded**.

**Original action item (no longer valid):** the candidate PKGBUILDs in `pkgbuilds/` MUST keep `libsoup` in `depends=`, not `optdepends=`. Any final patch sent to buzo should also ask him to revert this specific change.

**Corrected action item (2026-06-12):** since `libsoup-2.4` is no longer installable from the official repos, the candidate PKGBUILDs in `pkgbuilds/` must **provide** `libsoup-2.4.so.1` themselves — either by depending on the AUR `webkit2gtk` (which pulls libsoup-2.4 as a build dep / runtime optdep), or by bundling it directly per D.3. Adding `libsoup` to `depends=` is no longer possible because no `[extra]` / `[core]` / `[multilib]` package by that name exists.

## 2026-06-11 — `bind` as a runtime dep is unverified — superseded — ironhak, airv_zxf

> **Superseded (2026-06-12):** ironhak's [2026-06-12 03:53 AUR comment](https://aur.archlinux.org/packages/icaclient#comment-1074997) provides a reproducible scenario (first-launch StoreFront DNS resolution). See the 2026-06-12 entry "`bind` is needed for first-launch StoreFront DNS resolution (verified, not just libsoup)" for the full reproduction. **Action item:** add `bind` to `optdepends=` (not `depends=` — the failure is environment-specific).

ironhak claimed on 2026-03-22 (and again on 2026-06-11) that `bind` is needed for icaclient to work properly. Searched the Citrix install tree (`/opt/Citrix/ICAClient/`) for `nslookup`, `dig`, `host`, `libbind`, and found nothing. The Citrix binaries don't have a hard NEEDED on `libbind`.

**Possible explanations:** (a) the request is based on a specific DNS resolution issue ironhak hit that we haven't reproduced, (b) it's based on a misremembered fix, (c) it's an embedded NSS call that on some distros requires `libbind` (unusual on Arch where glibc's resolver is enough).

**Action item (originally):** ask ironhak for the specific error message or a log line. Do not add `bind` to depends without a reproducible case.

**Action item (revised, 2026-06-12):** add `bind` to `optdepends=`, not `depends=`, with a clear message. The failure is real but environment-specific (it happens on Manjaro and Suse per the BBS thread, not every Arch user). See the new 2026-06-12 entry for details.

## 2026-06-11 — `gdk-pixbuf2-noglycin` workaround no longer needed — informational — emild
emild reported on 2026-04-04 that the "stays stuck on Connecting..." bug was fixed upstream in 26.01.0.150. Confirmed: the gdk-pixbuf2 dep in the current PKGBUILD is `gst-plugins-base-libs`, which pulls in gdk-pixbuf2 as a transitive dep, but the `noglycin` patch is no longer required.

**Action item:** none. Just record so we don't re-suggest the workaround if a similar symptom appears.

---

## Open questions

- [ ] Does D.3 work end-to-end on a real session, not just ldd? (Partially answered by rogueai 2026-06-12: `selfservice` starts; injected-bundle path still fails; no real GUI session yet. Needs a tester with a real Citrix farm.)
- [ ] Does D.3 work in Wayland sessions, not just X11?
- [ ] Does the bundled webkit2gtk 2.36.0 work with the HDX/Microsoft Teams optimization? (Citrix might have webkit-version-dependent code paths)
- [ ] Does Citrix ever update the tarball with a newer webkit2gtk? (Would make the 2.36.0-vs-CVE concern moot.)
- [ ] Is there an ABI-compatible fork of webkit2gtk-4.0 maintained by someone outside Arch/AUR? (e.g., a distro that still ships it)
- [x] Ironhak's actual `bind` error — what is it, and is it actually fixed by installing `bind`? **Resolved 2026-06-12**: see entry "`bind` is needed for first-launch StoreFront DNS resolution (verified, not just libsoup)".
- [ ] Should the bundled libs be their own AUR sub-package (D.4) so other Citrix clients (e.g., `bin32-citrix-client`) can reuse them?
- [ ] **Where does `libsoup-2.4.so.1` come from for a self-contained D.3?** Single biggest blocker; see "What the bundle does NOT contain" in [`docs/alternatives.md`](../docs/alternatives.md).
- [ ] **D.3 path patching strategy: (a) NUL-pad string replacement vs (b) replicate the Debian multiarch path.** Decide before sending to buzo; switching later is a data-migration headache for installed users.
- [ ] Should we add `lldpd` as optdepend for e911 / Microsoft Teams optimized location services? (bstrdsmkr 2026-06-11, capadocia 2025-09-22. Reported as missing in `pkgbuilds/latest/PKGBUILD`.) **Resolved 2026-06-12**: implemented in `pkgbuilds/add-lldpd-bind-optdeps/`; see entry "Variant `add-lldpd-bind-optdeps`".

