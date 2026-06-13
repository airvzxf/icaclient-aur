# Glossary

Terms used throughout this repo and the AUR discussion, with the precise meaning we intend.

## ABI (Application Binary Interface)

The contract between a compiled binary and the libraries it calls. If the ABI changes (function signatures, struct layouts, calling conventions, versioned symbol tags), binaries compiled against the old ABI will not work with the new one — even if the filename is similar.

For webkit2gtk, the ABI changes between -4.0 and -4.1 because of the libsoup-2 → libsoup-3 transition, among other things. See [docs/webkit2gtk-abi.md](webkit2gtk-abi.md) for the detailed explanation.

## AUR (Arch User Repository)

The community-maintained repository of package build scripts (`PKGBUILDs`) for Arch Linux. Packages from AUR are not supported by Arch itself; each PKGBUILD has a maintainer who is the only person who can push to its git on the AUR server. Contributions happen by:
- E-mailing the maintainer a patch
- Cloning the AUR git, modifying, and asking the maintainer to pull
- In rare cases, the maintainer adding a co-maintainer

The icaclient AUR git is at `https://aur.archlinux.org/icaclient.git` (or browse via the cgit web UI at `https://aur.archlinux.org/cgit/aur.git/log/?h=icaclient`).

## AUR comment thread

The chronological list of comments on the AUR package page (`https://aur.archlinux.org/packages/icaclient`). Anyone with an AUR account can comment. The maintainer usually responds to relevant comments. The thread is searchable, never expires, and is the canonical place for "is this package still maintained?" type questions.

## build dep / makedep / checkdep / optdep

Categories of dependencies in a PKGBUILD:

- `depends=` — required at runtime
- `makedepends=` — required to build the package but not at runtime
- `checkdepends=` — required only for the check phase (often empty)
- `optdepends=` — optional, installed by the user if they want the extra feature

Moving something from `depends=` to `optdepends=` is **not** a no-op: it means the package can be installed without that thing, and breaks at runtime if the thing is missing. The AUR toolchain (makepkg, pacman) will not warn the user at install time that they have a missing optdep — only at runtime when the binary tries to load it.

## Citrix Workspace (a.k.a. selfservice, ICAClient, Citrix Receiver)

The product line. "Citrix Workspace" is the current brand name. The package is called `icaclient` because the underlying protocol is ICA (Independent Computing Architecture) and the directory is `/opt/Citrix/ICAClient/`. "Citrix Receiver" was the previous name. "selfservice" is the GUI application that lets a user browse and launch their assigned apps/desktops.

## ICU (International Components for Unicode)

A library that webkit2gtk uses heavily for text rendering, unicode handling, locale data, etc. ICU has its own ABI version: ICU 50, 60, 70, 78, etc. The Citrix bundle ships ICU 70 (March 2022) even though current Arch has ICU 78. This is fine as long as the bundle's ICU libs are installed alongside, which is what D.3 does.

## `ldd` vs `readelf -d NEEDED`

- `ldd <binary>` shows the **complete** resolution tree, including libraries pulled in transitively.
- `readelf -d <binary> | grep NEEDED` shows only the **direct** dependencies.

For figuring out what a binary *really* needs to start, `NEEDED` is more accurate (the linker will refuse to start if a direct NEEDED is missing). For figuring out what shared objects are *actually* loaded at runtime, `ldd` is more accurate (it shows transitive deps, but only after the binary has started).

When debugging "is the bundle actually being used?" prefer `ldd` and look for the `/opt/Citrix/ICAClient/lib/...` path in the resolved paths.

## libsoup-2 vs libsoup-3

GNOME's HTTP library. Version 2 (`libsoup-2.4.so.1`) is the long-stable line. Version 3 (`libsoup-3.0.so.0`) is the current line, with API changes (notably: GObject properties instead of setters, no more `SoupSessionAsync`, async-only signals, etc.). Loading both in the same process is explicitly blocked by glib (you'll see `libsoup-ERROR **: libsoup2 symbols detected.`).

The Arch package `libsoup` provides version 2.4; the package `libsoup3` provides version 3.0. They can coexist on the system; they just cannot both be loaded into the same process.

## makepkg / pacman

- `makepkg` — reads a PKGBUILD, downloads sources, compiles (if applicable), produces a `.pkg.tar.zst` file
- `pacman -U <pkg.tar.zst>` — installs a local package file
- `pacman -S <name>` — installs from configured repos
- `pacman -R <name>` — removes
- `pacman -Rdd <name>` — removes, ignoring dependency checks (use with care)

AUR helpers like `yay` and `paru` wrap these: they clone the AUR git, run `makepkg`, then `pacman -U` the result.

## NEEDED

A direct dependency declared in an ELF binary's dynamic section. Enforced by the dynamic linker at load time. If a NEEDED library cannot be found in the loader's search path (which includes `/etc/ld.so.conf`, `LD_LIBRARY_PATH`, RPATH, RUNPATH, and the default system paths), the binary fails to start with `error while loading shared libraries: libFOO.so: cannot open shared object file`.

## patchelf

A tool to modify ELF binaries post-build. Useful for:
- `patchelf --set-rpath <path>` — embed a RUNPATH into a binary
- `patchelf --set-rpath '$ORIGIN'` — set RUNPATH to the directory of the binary (so it finds libs in the same dir)
- `patchelf --set-rpath '$ORIGIN/lib'` — set RUNPATH to a subdir named `lib`
- `patchelf --replace-needed <old> <new>` — rewrite a NEEDED entry (fragile, use with care)

`$ORIGIN` is a magic token that expands at runtime to the directory containing the binary (or `.so`) being loaded. It is the standard way to make a self-contained relocatable bundle.

## RUNPATH vs RPATH

Both are embedded search paths in ELF. RUNPATH (DT_RUNPATH) is searched *after* `LD_LIBRARY_PATH`; RPATH (DT_RPATH) is searched *before*. For our purposes, RUNPATH is what we want — it lets the user override with `LD_LIBRARY_PATH` if they're debugging. `patchelf --set-rpath` actually sets RUNPATH in modern patchelf, despite the name.

## selfservice

The GUI application (`/opt/Citrix/ICAClient/selfservice`) that lets users browse and launch their Citrix-assigned apps and desktops. It uses webkit2gtk-4.0 to render the storefront page. This is the binary most affected by the webkit2gtk dependency problem.

## UIDialogLibWebKit3.so

A shared library shipped by Citrix at `/opt/Citrix/ICAClient/lib/UIDialogLibWebKit3.so`. It is loaded by `wfica` at runtime (via `dlopen`) when `wfica` needs to display a dialog (e.g., the "Connecting..." dialog, error dialogs, certificate prompts). It uses webkit2gtk-4.0 to render these dialogs. Its direct NEEDED on `libwebkit2gtk-4.0.so.37` and `libsoup-2.4.so.1` is the technical reason why `wfica` "appears to work" without webkit2gtk-4.0 for users who never see a dialog.

## webkit2gtk / webkit2gtk-4.0 / webkit2gtk-4.1 / webkitgtk-6.0

The naming is confusing. Historical context:

- `webkit2gtk` was the original metapackage in Arch. It provided the **4.0** ABI.
- After the 4.0 ABI was deprecated upstream, Arch split into:
  - `webkit2gtk-4.1` (still GTK3, but libsoup-3)
  - `webkitgtk-6.0` (GTK4, libsoup-3)
- The `webkit2gtk` metapackage was **moved to AUR** (still provides 4.0 ABI for legacy use).
- `webkit2gtk-imgpaste` is an AUR package with the same content as AUR `webkit2gtk` (4.0 ABI), with a saner name and an added image-paste extension.

If you see references to "webkit2gtk" without a version suffix, in Arch context it usually means the 4.0 ABI package (now AUR). In the AUR, the package is literally named `webkit2gtk` (not `webkit2gtk-4.0`).

## wfica

The main Citrix client binary (`/opt/Citrix/ICAClient/wfica`). It opens `.ica` files and connects to a Citrix farm. It does not have webkit2gtk in its direct NEEDED list; it loads `UIDialogLibWebKit3.so` only when it needs to display a dialog. This asymmetry is why "wfica works for me without webkit2gtk" can be true while "selfservice works for me without webkit2gtk" is not.

## x86_64-linux-gnu

The Debian/Ubuntu multiarch path inside which Debian packages install their libraries. When you see `usr/lib/x86_64-linux-gnu/libwebkit2gtk-4.0.so.37` inside a Debian package, it means the file is at `usr/lib/x86_64-linux-gnu/` and ends up at `/usr/lib/x86_64-linux-gnu/libwebkit2gtk-4.0.so.37` when installed. On Arch, the equivalent path is `/usr/lib/libwebkit2gtk-4.0.so.37` (no `x86_64-linux-gnu` segment). The D.3 candidate PKGBUILD has to flatten this path when extracting the bundle.
