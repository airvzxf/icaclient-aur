# The webkit2gtk-4.0 ABI and why it matters for icaclient

**Audience:** anyone trying to understand why `icaclient` keeps breaking, what the available fix paths are, and why several "obvious" fixes don't work.

## TL;DR

Citrix compiled `selfservice` and the dialog library `UIDialogLibWebKit3.so` (loaded by `wfica` at runtime) against the **webkit2gtk-4.0** ABI. That ABI uses **libsoup-2.4**. Arch dropped the `webkit2gtk` (4.0 ABI) metapackage from the official repositories; only `webkit2gtk-4.1` and `webkitgtk-6.0` remain, both of which use **libsoup-3.0** and are **not ABI-compatible** with -4.0. The `webkit2gtk` (4.0 ABI) package now lives only in the AUR, and compiling it from source takes several hours.

A symlink hack (`libwebkit2gtk-4.0.so.37 → libwebkit2gtk-4.1.so.0`) appears to "work" for some users but actually crashes for anyone using `selfservice` or the `wfica` connection dialog. The 4.0 ABI is not a magic incantation — it is a contract between the Citrix binaries and the system libraries.

---

## What "ABI" actually means here

A `.so` filename is a promise, not a guarantee. `libwebkit2gtk-4.0.so.37` and `libwebkit2gtk-4.1.so.0` have the same prefix but they are **not** the same library:

- They depend on **different versions of libsoup** (2.4 vs 3.0).
- They expose **different GIR namespaces** and internal types.
- They use **different versions of glib's type system** in subtle ways.
- The C function signatures differ in places (e.g., `webkit_web_view_load_uri` vs `webkit_web_view_load_uri` with a different `WebKitLoadEvent` enum).

A symlink `libwebkit2gtk-4.0.so.37 → libwebkit2gtk-4.1.so.0` will make `dlopen` succeed but the **first** call into the library that uses libsoup-2 types will fail. The actual error message comes from glib (not from webkit2gtk itself):

```
libsoup-ERROR **: HH:MM:SS: libsoup2 symbols detected. Using libsoup2 and libsoup3 in the same process is not supported.
```

This is the exact error buzo saw on 2026-06-10 when testing the `webkit2gtk-4.1` substitution idea. The error means: "glib has detected that symbols from libsoup-2 and libsoup-3 are both loaded into the process address space, which it does not allow."

There is no configuration, no environment variable, and no symlink trick that fixes this. The libraries are simply incompatible at the binary level.

---

## What Citrix's binaries actually need

Run on a working install (verified on Arch with `icaclient 26.01.0.150-2`):

```bash
$ readelf -d /opt/Citrix/ICAClient/selfservice | grep -iE "needed" | grep -iE "webkit|soup"
 (NEEDED) libsoup-2.4.so.1
 (NEEDED) libwebkit2gtk-4.0.so.37

$ readelf -d /opt/Citrix/ICAClient/lib/UIDialogLibWebKit3.so | grep -iE "needed" | grep -iE "webkit|soup"
 (NEEDED) libsoup-2.4.so.1
 (NEEDED) libwebkit2gtk-4.0.so.37
```

Three things to note:

1. **Both binaries need `libsoup-2.4.so.1`, not `libsoup-3.0.so.0`.** This is independent of webkit2gtk. Even if we could use webkit2gtk-4.1, the Citrix code itself uses libsoup-2 APIs.

2. **`wfica` does not have webkit in its NEEDED list.** It loads `UIDialogLibWebKit3.so` at runtime (via `dlopen`) only when it needs to show a dialog. That is why users who only run `wfica` on `.ica` files from a browser never see the webkit error — that code path does not trigger the dialog.

3. **Citrix does not bundle a local copy of `libsoup-2.4`.** Verified:
   ```bash
   $ find /opt/Citrix/ICAClient -name "libsoup*"
   (no results)
   ```
   So the system must provide `libsoup-2.4.so.1`. Arch's `libsoup` package (`2.74.3-4` at the time of writing) does this. `libsoup3` is a separate package.

---

## Why a symlink hack "works" for some users

If you do:

```bash
ln -s /usr/lib/libwebkit2gtk-4.1.so.0 /usr/lib/libwebkit2gtk-4.0.so.37
ln -s /usr/lib/libjavascriptcoregtk-4.1.so.0 /usr/lib/libjavascriptcoregtk-4.0.so.18
```

Two things happen:

1. `dlopen("libwebkit2gtk-4.0.so.37")` succeeds — the file exists, the symlink resolves.
2. **The first call into a libsoup-2 API fails.** For `wfica` users, that call may never happen if the connection dialog is never shown (e.g., the `.ica` file is launched silently, the connection succeeds, the session UI takes over directly). For `selfservice` users, the call happens immediately on startup.

So "it works" with a symlink is **real for the `wfica`+`.ica` workflow and an illusion for the `selfservice` workflow**. The illusion is the dangerous part: a user who only ever uses `wfica` will believe their install is healthy, and then break it the first time they need to use `selfservice` (e.g., their company blocks the web portal and forces them to use the desktop app).

---

## What icaclient's package needs to provide

To make **`selfservice` work** (and `wfica`'s connection dialog), the system must provide:

- `libwebkit2gtk-4.0.so.37` — the 4.0 ABI
- `libjavascriptcoregtk-4.0.so.18` — the matching JavaScript engine ABI
- `libsoup-2.4.so.1` — libsoup 2, **not** 3
- `libicu*.so.70` — the ICU version Citrix compiled against (this is **ICU 70**, not the system's current ICU 78; this is non-obvious and a common source of subtle breakage if not handled)
- Plus the standard GTK3 stack: pango, cairo, gdk-pixbuf, gtk3, glib2, and friends

For **`wfica`+`.ica` from browser, no dialog needed**: only `libsoup-2.4.so.1` is strictly required at the binary level (plus the basic GTK3 stack that `wfica` itself uses). The webkit libraries are loaded transitively only if a dialog has to be shown.

---

## Why icaclient's `depends=` looks the way it does

As of 2026-06-11, the upstream AUR PKGBUILD declares:

```bash
depends=(alsa-lib curl gst-plugins-base-libs libc++ libc++abi
         libsecret libsoup libvorbis libxaw libxml2-legacy libxp
         openssl speex)
optdepends=('webkit2gtk: needed for Citrix Workspace (selfservice)')
```

- `libsoup` is a **hard dep** because the runtime NEEDED analysis above shows it is required by both `selfservice` and `UIDialogLibWebKit3.so`.
- `webkit2gtk` is **optdepend** because the maintainer accepted a "doesn't actually need it" framing for the `wfica`+`.ica` workflow. That framing is **partially correct** for wfica-only users and **incorrect** for selfservice users.

On 2026-06-11, buzo also moved `libsoup` to `optdepends`, in response to johnnybash's claim that "libsoup got dropped to the AUR". This is **factually wrong** (libsoup is in `[extra]`, not AUR) and **functionally a regression** (it will break the package for users who don't have libsoup installed). See [CHANGELOG.md](../CHANGELOG.md) for the full reasoning and the action item to ask buzo to revert this specific change.

---

## The 4 paths forward

See [docs/alternatives.md](alternatives.md) for the full evaluation. Short version:

1. **Status quo (optdepends)** — works for wfica-only users, breaks selfservice.
2. **Quick fix** — revert the `libsoup` regression, keep `webkit2gtk` as optdepend, improve the message. Good interim.
3. **D.3 (bundle upstream prebuilt libs)** — fully self-contained, no AUR webkit2gtk dep. The prebuilt libs are already in the Citrix tarball.
4. **D.4 (build precompiled libs in an AUR sub-package)** — automated version of D.3.

D.3 is currently the most promising candidate but needs end-to-end testing on a real session (S6 in [TESTING.md](../TESTING.md)) before being promoted.

---

## References

- Arch wiki: [webkit2gtk](https://wiki.archlinux.org/title/WebKitGTK) (mostly outdated, but useful historical context)
- webkitgtk.org security advisories: https://webkitgtk.org/security.html — the WSA-* list of CVEs, useful for evaluating the risk of shipping an older webkit (the bundle is 2.36.0, from March 2022)
- libsoup release notes for v3: https://gitlab.gnome.org/GNOME/libsoup/-/releases (search for the 3.0.0 release; the API changes are documented there)
- The AUR package page: https://aur.archlinux.org/packages/icaclient
