# Testing infrastructure

The scenarios in [`TESTING.md`](../TESTING.md) (S1-S7) are the **what** to test. This document is the **how**: the tooling that makes "I tested it" mean something reproducible rather than "I ran it on my laptop and it worked".

The approach is layered: each layer verifies a different class of failure, and you use several in combination. The layers are ordered by isolation strength (weakest to strongest).

## The 5 layers

| Layer | Tooling | What it isolates | What it does NOT isolate | Use for | Cycle time |
|---|---|---|---|---|---|
| **L0 — Static lint** | `namcap PKGBUILD` | nothing (static) | nothing | Detect missing `makedepends`, bad refs, common mistakes | < 1 s |
| **L1 — Dirty build** | `makepkg` (uses `fakeroot`) | fake root permissions | everything else on your system | Fast iteration while writing the PKGBUILD | 1-15 min |
| **L2 — Clean build** | `makechrootpkg` (from `devtools`) | a minimal Arch chroot with only `base` + `base-devel` | the kernel, /tmp, network, /dev | **S5 (build time), S7 (no spurious new deps) honestly** — what the official Arch build server uses | 1-15 min |
| **L3 — Container with GUI forwarded** | `systemd-nspawn`, `podman`, `bubblewrap`, or `distrobox` | own rootfs, namespaces; optionally own net | can see the host (configurable) | **S1, S2, S3** (launch `selfservice` and `wfica`, see the GUI on the host) | 30 s - 5 min to start |
| **L4 — Full VM** | QEMU/KVM + libvirt + SPICE | **everything** — own kernel, own drivers, isolatable network | nothing (it's a separate OS) | **S6 (real Citrix session)**, reproducing bugs, validating on old kernels or different distros | 30 s - 2 min to start |

**`fakeroot` (which you already use) is L1.** **`makechrootpkg` is L2.** The difference matters: `fakeroot` does not detect a missing `makedepends=gtk3` because you have `gtk3` installed; `makechrootpkg` does, because the chroot does not.

## L0 — Static lint with `namcap`

[`namcap`](https://man.archlinux.org/man/namcap.1) parses a `PKGBUILD` and reports common mistakes.

```bash
$ namcap pkgbuilds/bundle-4.0-icu70/PKGBUILD
pkgbuilds/bundle-4.0-icu70/PKGBUILD W: Dependency gtk3 detected and... (many more)
```

**W** = warning (cosmetic or potential issue), **E** = error (the package will not build or will not work). Warnings are expected and often wrong about AUR packages; treat errors as blockers.

`namcap` does **not** verify ABI compatibility, library resolution, or whether the package actually works. It is a fast pre-flight check, not a substitute for L2 or L3.

## L2 — Clean build with `makechrootpkg`

`makechrootpkg` (part of [`devtools`](https://man.archlinux.org/man/makechrootpkg.1)) builds the package in a chroot that contains only `base` and `base-devel` — exactly the state of a fresh Arch install. This is the same setup the official Arch build servers use to build `[core]`, `[extra]`, and `[multilib]`.

### One-time setup

```bash
# Pick a chroot location; default is ~/.local/chroots/arch-citrix
mkdir -p ~/.local/chroots/arch-citrix

# Create the chroot (downloads base + base-devel, ~2-3 GB the first time)
mkarchroot -M /dev/null ~/.local/chroots/arch-citrix/root base-devel
```

`mkarchroot` does *not* run pacman sync; you can do that yourself with `arch-nspawn` if you need extra packages in the chroot (e.g., for the `D.3` variant, you will want `patchelf`):

```bash
sudo arch-nspawn ~/.local/chroots/arch-citrix/root pacman -S patchelf
```

### Build

```bash
cd pkgbuilds/bundle-4.0-icu70
makechrootpkg -c -r ~/.local/chroots/arch-citrix -- --nocheck
```

The `-c` flag cleans the chroot before the build (removes anything left from a previous build). The trailing `--` separates `makechrootpkg` options from the inner `makepkg` options; `--nocheck` skips the `check()` function (Citrix does not ship one).

The first build downloads the Citrix tarball (~280 MB) and any other sources. Subsequent builds use the makepkg cache in the chroot.

### What you learn from L2

- Does the build complete in a clean environment? (Detects `makedepends` you forgot.)
- How long does it take? (**S5** in the test matrix.)
- Did the build pull in unexpected new packages into the chroot? (**S7** in the test matrix — diff `pacman -Qe` before/after.)
- Does the resulting `.pkg.tar.zst` install cleanly?
- What does `ldd` and `readelf -d` report on the installed binaries?

`makechrootpkg` does **not** give you a GUI to look at. For that, see L3.

### Orchestrator: `scripts/test-variant.bash`

The `scripts/test-variant.bash` script (with helpers in `scripts/lib/test-common.bash` and `scripts/lib/citrix-smoke.bash`) automates L0, L2, the L3 launch sequence described below, and an **optional automated S1-S3 smoke test** (library-level checks). For most testers, the script is the entry point — the manual commands in the L0/L2/L3 sections above are the reference, but you do not need to type them by hand.

```bash
# Lint only (fast, no chroot needed)
scripts/test-variant.bash <variant-name> --no-build

# Lint + clean build (creates the chroot on first run, ~2-3 GB download)
scripts/test-variant.bash <variant-name>

# Lint + clean build + enter a GUI smoke-test sandbox
scripts/test-variant.bash <variant-name> --sandbox=distrobox
scripts/test-variant.bash <variant-name> --sandbox=nspawn
scripts/test-variant.bash <variant-name> --sandbox=podman

# Lint + clean build + automated S1/S2/S3 smoke test (library-level)
# + enter the sandbox shell for any remaining manual validation
scripts/test-variant.bash <variant-name> --sandbox=nspawn --smoke-test

# Same, but leave wfica alive after S3 for visual inspection of the
# "Connecting..." dialog (selfservice is always killed at S1)
scripts/test-variant.bash <variant-name> --sandbox=distrobox --smoke-test --keep-running
```

The script auto-detects the host's display server, audio server, GPU, and sudo mode, then assembles the correct `arch-nspawn` / `podman run` / `distrobox create` arguments. It also prints the four chroot-side checklist outputs from the "Local checklist" in [`TESTING.md`](../TESTING.md) (the fifth, `journalctl`, is host-side and stays manual).

#### Automated S1-S3 smoke test (`--smoke-test`)

The `--smoke-test` flag runs an automated, library-level validation of S1, S2, S3 inside the L3 sandbox, before `exec`-ing into the shell. The implementation:

- Sample `.ica` files in [`scripts/test-fixtures/`](../scripts/test-fixtures/) point at `192.0.2.1:1494` (IANA TEST-NET-1, RFC 5737 — non-routable). `wfica` will parse the file, attempt a TCP connection, hang on the SYN, and show the "Connecting..." dialog (S3) — exactly the code path the S1-S3 protocol is designed to exercise, with no real Citrix farm required.
- The smoke-test library ([`scripts/lib/citrix-smoke.bash`](../scripts/lib/citrix-smoke.bash)) launches `selfservice` (S1) and `wfica <fixture.ica>` (S2, S3) in fully-detached background processes, captures stderr, waits for the process to stay alive (catches immediate crashes), then validates:
  - **S1**: `/proc/<selfservice-pid>/maps` contains `libwebkit2gtk-4.0.so.37` and `libsoup-2.4.so.1` (loaded via `dlopen` at startup).
  - **S2**: `wfica` is alive after the `.ica` is processed.
  - **S3** (strong signal): `WebKitWebProcess` or `WebKitNetworkProcess` is a child of the `wfica` process (the dialog is actively rendering). **S3** (weak signal, fallback): `UIDialogLibWebKit3.so` can resolve `libwebkit2gtk-4.0.so.37` via `ldd` (catches the "library not found" failure mode even if the dialog hasn't rendered yet within the wait window).
- The driver is [`scripts/test-fixtures/run-smoke.bash`](../scripts/test-fixtures/run-smoke.bash). The orchestrator stages the fixtures + the smoke library into a temp dir and bind-mounts it at `/opt/citrix-smoke/` inside the sandbox (or `$XDG_CACHE_HOME/citrix-smoke-staging/` for distrobox, which auto-shares `$HOME`).
- `--keep-running` (only meaningful with `--smoke-test`) leaves `wfica` alive after S3 for visual inspection of the "Connecting..." dialog. `selfservice` is always killed at S1.

**What the smoke test does NOT automate:**

- **S6 (real Citrix session)** — requires a real farm. The smoke test only validates the library-level pipeline; the actual session connect is the tester's job (run `wfica` manually with a real `.ica`).
- **Visual inspection of windows** — the test is library-level. "The dialog appears" is a visual fact; the test verifies "the libraries that would render the dialog are loaded into the process". The S3 strong signal (a `WebKit*` helper is running) is the closest proxy without screen scraping.
- **The "GUI window appears" part of S1 / S3** — see above. For full visual validation, the tester opens the GUI manually after the smoke test reports pass (or uses `--keep-running` for S3).

**Pre-flight** (in the smoke library, before any launch):

```
[smoke] /opt/Citrix/ICAClient/{selfservice,wfica} not found.
[smoke]   Install the icaclient package first:
[smoke]     - nspawn: already done by L2 (or re-run the script without --no-build)
[smoke]     - distrobox / podman: cd into the variant dir, run 'makepkg -si',
[smoke]       then re-run the orchestrator with --smoke-test.
```

This means: with `--sandbox=nspawn --smoke-test`, the smoke test runs immediately after the L2 install (no extra step). With `--sandbox=distrobox --smoke-test` or `--sandbox=podman --smoke-test`, the tester installs the package manually inside the sandbox, exits, and re-runs the orchestrator with `--smoke-test` (the L2 build artifacts are cached, so the re-run is fast).

**Result format** (lines on stderr, grep-friendly):

```
[smoke] ===== SUMMARY =====
[PASS]  S1
[PASS]  S2
[PASS]  S3
```

`shellcheck -x scripts/test-variant.bash scripts/lib/test-common.bash scripts/lib/citrix-smoke.bash scripts/test-fixtures/run-smoke.bash` is part of the validation flow for any change to these files.

## L3 — GUI smoke test: three options

L3 runs the Citrix binaries (or any GUI app) inside a container/chroot, but the display is forwarded to the host's X server or Wayland compositor. The app's windows appear on your screen; the app itself does not run on the host.

You have three tools to choose from. Pick by your priorities:

| Option | Simplicity | Isolation | GPU passthrough | Distro availability | Best for |
|---|---|---|---|---|---|
| **Distrobox** | high (auto-forwards) | medium (own rootfs, shared /home) | easy (`--nvidia` flag) | AUR + Flatpak (host pkg, not in [extra]) | Testers new to containers; quick iteration |
| **systemd-nspawn** | medium (manual bind mounts) | medium (own rootfs, optional unsharing) | manual (`--device /dev/dri`) | ships with `systemd` | CI-friendly; no extra deps |
| **Podman** | low (verbose flags) | high (rootless, full namespaces) | manual + nvidia hook for NVIDIA | `[extra]` | Container purists; reproducible environments |

`bubblewrap` is a fourth option, even more lightweight, but ephemeral and harder to keep state in. Not recommended for the multi-step icaclient test.

### Common: detecting your display, audio, and GPU

Before choosing a sandbox, know what your host has. Save this snippet as `~/.local/bin/detect-display-stack` (or run it inline):

```bash
#!/usr/bin/env bash
# Detect what GUI / audio / GPU stack the host has.

# Display
if [ -n "$WAYLAND_DISPLAY" ] && [ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]; then
    echo "Display: Wayland (compositor: $WAYLAND_DISPLAY, socket: $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY)"
elif [ -n "$DISPLAY" ] && [ -S "/tmp/.X11-unix/X${DISPLAY#:}" ]; then
    echo "Display: X11 (display: $DISPLAY, socket: /tmp/.X11-unix/X${DISPLAY#:})"
else
    echo "Display: NONE (no graphical session detected - sandbox GUI will not work)"
fi

# Audio
if [ -S "$XDG_RUNTIME_DIR/pipewire-0" ]; then
    echo "Audio:   PipeWire (socket: $XDG_RUNTIME_DIR/pipewire-0)"
elif [ -S "$XDG_RUNTIME_DIR/pulse/native" ]; then
    echo "Audio:   PulseAudio (socket: $XDG_RUNTIME_DIR/pulse/native)"
else
    echo "Audio:   NONE (no audio server detected - Citrix session will be silent)"
fi

# GPU
if [ -d /dev/dri ]; then
    if lsmod 2>/dev/null | grep -q nvidia; then
        echo "GPU:     NVIDIA (kernel module loaded; nvidia-container-toolkit needed for Podman)"
    elif ls /dev/dri 2>/dev/null | grep -q renderD128; then
        echo "GPU:     Intel/AMD (DRM device present at /dev/dri)"
    fi
else
    echo "GPU:     NONE (software rendering only - webkit2gtk will be slow)"
fi
```

### Option A: Distrobox

[Distrobox](https://github.com/89luca89/distrobox) is a wrapper that auto-forwards X11, Wayland, audio, D-Bus, the user's home, and (with `--nvidia`) the GPU. It is the lowest-friction option for a human-driven smoke test.

```bash
# One-time: create the test container
distrobox create --image archlinux:latest --name citrix-test

# Enter it (auto-forwards everything that matters)
distrobox enter citrix-test

# Inside: install the package, then test
[citrix-test@host ~]$ cd /tmp
[citrix-test@host tmp]$ git clone <your-fork-or-local-path> icaclient-aur
[citrix-test@host tmp]$ cd icaclient-aur/pkgbuilds/bundle-4.0-icu70
[citrix-test@host bundle-4.0-icu70]$ makepkg -si
[citrix-test@host bundle-4.0-icu70]$ /opt/Citrix/ICAClient/selfservice
# GUI appears on the host display. S1, S2, S3 can now be validated by eye.
```

For NVIDIA hosts:

```bash
distrobox create --image archlinux:latest --name citrix-test --nvidia
```

**Trade-off:** Distrobox is not in `[core]` or `[extra]` of Arch. On a stock Arch install, install it from AUR (`distrobox`) or via Flatpak. The host tools it uses (`podman` is the default backend) are in `[extra]`.

### Option B: systemd-nspawn

`arch-nspawn` (from `devtools`) boots a full systemd inside a chroot/rootfs. You bind-mount the host's display sockets explicitly. More verbose, but official (no extra deps beyond `devtools`).

For X11 hosts:

```bash
sudo arch-nspawn \
    -D ~/.local/chroots/arch-citrix/root \
    --bind=/tmp/.X11-unix \
    --bind-ro=$HOME/.cache/makepkg \
    --setenv=DISPLAY=$DISPLAY \
    --setenv=XAUTHORITY=$XAUTHORITY \
    --setenv=DBUS_SESSION_BUS_ADDRESS \
    /bin/bash
```

For Wayland hosts:

```bash
sudo arch-nspawn \
    -D ~/.local/chroots/arch-citrix/root \
    --bind-ro=$XDG_RUNTIME_DIR \
    --setenv=WAYLAND_DISPLAY=$WAYLAND_DISPLAY \
    --setenv=XDG_RUNTIME_DIR=/run/user/host-$(id -u) \
    --setenv=DBUS_SESSION_BUS_ADDRESS \
    /bin/bash
```

(Replace `host-` with the prefix your nspawn config uses; the default empty works for most setups.)

Add `--device /dev/dri` for GPU passthrough (Intel/AMD). For NVIDIA, see "GPU" below.

### Option C: Podman

Rootless containers, more isolation than nspawn. Verbose but explicit.

For X11 hosts:

```bash
podman run -it --rm \
    -v /tmp/.X11-unix:/tmp/.X11-unix:Z \
    -v $HOME/.cache/makepkg:/root/.cache/makepkg:Z \
    -e DISPLAY=$DISPLAY \
    -e XAUTHORITY=$XAUTHORITY \
    --security-opt label=type:container_file_t \
    --userns=keep-id \
    --device /dev/dri \
    archlinux:latest \
    /bin/bash
```

For Wayland hosts, swap the X11 bind for:

```bash
    -v $XDG_RUNTIME_DIR:/run/user/1000:Z \
    -e WAYLAND_DISPLAY=$WAYLAND_DISPLAY \
    -e XDG_RUNTIME_DIR=/run/user/1000
```

`--userns=keep-id` is critical for the X socket to be writable inside the container; without it the X server will reject the connection (different UID).

### Audio forwarding

`selfservice` does not need audio. **`wfica` does** (Citrix HDX sessions carry sound). Without forwarding, your session will be silent.

PulseAudio host:

```bash
# In nspawn:
--bind=$XDG_RUNTIME_DIR/pulse \
--setenv=PULSE_SERVER=unix:/run/user/host-$(id -u)/pulse/native

# In Podman:
-v $XDG_RUNTIME_DIR/pulse:/run/user/1000/pulse:Z
-e PULSE_SERVER=unix:/run/user/1000/pulse/native
```

PipeWire host (modern default; the PulseAudio-compatible socket is what you want):

```bash
# In nspawn: PipeWire-pulse usually exposes the same socket path
--bind=$XDG_RUNTIME_DIR/pulse \
--setenv=PULSE_SERVER=unix:/run/user/host-$(id -u)/pulse/native

# If that does not work, bind the PipeWire socket directly
--bind=$XDG_RUNTIME_DIR/pipewire-0 \
--setenv=PIPEWIRE_REMOTE=unix:/run/user/host-$(id -u)/pipewire-0
```

### D-Bus session bus

For clipboard, notifications, file dialogs. Most Citrix scenarios do not need it, but it does not hurt to forward it.

The D-Bus socket is at `$DBUS_SESSION_BUS_ADDRESS` (usually `unix:path=/run/user/$(id -u)/bus`). The `--setenv=DBUS_SESSION_BUS_ADDRESS` lines in the nspawn and Podman snippets above pick up the host's value automatically when the runtime dir is also bound.

### GPU passthrough

Intel/AMD (DRM device at `/dev/dri`):

```bash
# nspawn
--device /dev/dri

# Podman
--device /dev/dri
```

NVIDIA (requires the proprietary driver and, for Podman, `nvidia-container-toolkit`):

```bash
# Distrobox (easiest)
distrobox create --image archlinux:latest --name citrix-test --nvidia

# nspawn
# Mount the NVIDIA device files and libraries. systemd-nspawn on
# Arch (verified on systemd 260.2-2) does NOT recognize the
# --device= option (not in --help, rejected as "unrecognized
# option"). Use --bind= for the device nodes instead, which works
# on every systemd-nspawn version.
--bind=/dev/nvidia0
--bind=/dev/nvidiactl
--bind=/dev/nvidia-uvm
--bind=/usr/lib/x86_64-linux-gnu/libcuda.so* (or wherever the host has them)
--setenv=LIBGL_ALWAYS_SOFTWARE=0
--setenv=NVIDIA_DRIVER_CAPABILITIES=all

# Podman (with nvidia-container-toolkit installed)
--hook-spec=/usr/share/containers/oci/hooks.d/oci-nvidia-hook.json
# or use the nvidia-container-cli wrapper
```

If GPU passthrough fails, the fallback is software rendering (slow but works):

```bash
--setenv=LIBGL_ALWAYS_SOFTWARE=1
```

### sudo

Both `makechrootpkg` and `arch-nspawn` need root. The `scripts/test-variant.bash` orchestrator auto-detects which sudo mode the user has. Detection is **command-specific**: it runs `sudo -n -l` and looks for a `NOPASSWD` rule that covers one of the commands the script needs (not just `NOPASSWD: ALL`, not `true` or other unrelated commands). This way, a user with NOPASSWD only for `makechrootpkg` and `arch-nspawn` is correctly classified as "passwordless", even though `sudo -n true` would still prompt.

- **Passwordless** (`/etc/sudoers` has a `NOPASSWD` rule for at least one of: `makechrootpkg`, `arch-nspawn`, `mkarchroot`, `btrfs`, `mount`, `umount`): the script invokes `sudo` internally for those commands without prompting.
- **Interactive** (no such `NOPASSWD` rule): the script aborts with a clear message. The user must either re-run with `sudo scripts/test-variant.bash ...` (and type the password once; sudo caches the timestamp for 5 minutes by default), or add a `NOPASSWD` rule as shown below.

To set up passwordless sudo for the specific commands the script needs:

```bash
sudo visudo
# Add (replace `youruser` with your username):
youruser ALL=(ALL) NOPASSWD: /usr/bin/makechrootpkg, /usr/bin/arch-nspawn, /usr/bin/mkarchroot, /usr/bin/btrfs, /usr/bin/mount, /usr/bin/umount
```

**Do not** use `NOPASSWD: ALL` — that disables sudo's safety net entirely.

#### Why the script uses `arch-nspawn -f` (not `cp` or stdin) to install the built package

The L2 phase builds a `.pkg.tar.zst` on the host, then installs it into the chroot so the chroot-side checklist outputs (`readelf -d`, `ldd`, `pacman -Q`) can inspect the installed binaries. The mechanics of "get a file from the host into the chroot" are non-obvious because:

- **`cp` from host to `$CHROOT_ROOT/tmp/...` requires sudo**, and `cp` is usually not in a user's NOPASSWD list. `rm` has the same problem.
- **Piping via stdin does not work**: `systemd-nspawn` does not propagate the host's stdin to the chroot command, so `cat foo.pkg.tar.zst | sudo arch-nspawn CHROOT tee /tmp/foo` writes "foo" to the *host* stdout, not the chroot's filesystem.
- **Bind mounts require the mount point to exist** (`mkdir /tmp/foo` inside `arch-nspawn` does not persist because `systemd-nspawn` mounts a fresh tmpfs on `/tmp` per session), and `mkdir`/`mount`/`umount` are a wider attack surface to authorize than just `arch-nspawn`.

The script uses `arch-nspawn -f <host>:<chroot>` instead: `-f` does a host-side `cp -T` to the chroot path (bypassing the in-namespace tmpfs) and the destination must be on the chroot's persistent filesystem (e.g., `/opt/.citrix-test-stage/...`, not `/tmp/...`).

#### Why the script seeds `/etc/makepkg.conf` from the host

`mkarchroot` accepts a `-M <file>` flag to seed the chroot's `/etc/makepkg.conf`. If you pass `/dev/null` (or omit `-M`), the chroot has an empty makepkg.conf and `makepkg` inside the chroot fails immediately with `$SRCEEXT does not contain a valid package suffix`. The script passes `-M /etc/makepkg.conf` on chroot creation, and as a defensive check after the chroot exists: if the file is empty (e.g., the chroot was created with an older version of this script), it is overwritten with the host's makepkg.conf via `arch-nspawn` with stdin redirection (this is one of the few places stdin redirection works — the source is on the host, the destination is a file inside the chroot, and `arch-nspawn`'s `--pipe` semantics happen to handle it correctly).

## L4 — Full VM (QEMU/KVM)

Out of scope for the current infrastructure build. If a tester needs it (e.g., to validate against an old kernel or a different distro for S6), use `virt-manager` or `virt-install --graphics spice` with the SPICE display. SPICE gives native display, copy-paste between host and guest, and resolution changes. Document the VM XML in the repo if a specific config becomes common.

## Known limitations

- **S6 (real Citrix session) cannot be tested in CI.** It requires network access to a Citrix farm, which most contributors do not have. The test matrix (see [`docs/test-matrix-template.md`](test-matrix-template.md)) already treats S6 as `⏭️ skipped` for most testers; the promotion criteria accept this.
- **`xvfb` is not a substitute for a real display.** webkit2gtk needs GPU acceleration; Citrix HDX needs the network stack of a real session. Use a real display via L3, not a virtual one.
- **GPU passthrough on NVIDIA is finicky.** If it does not work on the first try, fall back to software rendering for the build verification; report the issue with `nvidia-container-toolkit` separately.
- **The Citrix tarball is ~280 MB.** First build in a fresh chroot downloads it; subsequent builds use the cache. The makechrootpkg cache is in the chroot itself; the L3 sections above show how to mount the host's `$HOME/.cache/makepkg` to share it.
- **The bundled webkit2gtk is 2.36.0 (March 2022).** It has unpatched CVEs (see [WSA-* advisories](https://webkitgtk.org/security.html)). This is a Citrix-side decision, not something the PKGBUILD can fix. D.3 ships what Citrix ships.

## See also

- [`TESTING.md`](../TESTING.md) — the S1-S7 protocol this infrastructure supports
- [`docs/alternatives.md`](alternatives.md) — the variant proposals
- [`docs/test-matrix-template.md`](test-matrix-template.md) — how to record results
- [`docs/workflow.md`](workflow.md) — labels and status lifecycle
- [`CONTRIBUTING.md`](../CONTRIBUTING.md) — how to participate
- [Arch wiki: Makepkg](https://wiki.archlinux.org/title/Makepkg)
- [Arch wiki: makepkg#Build in a clean chroot](https://wiki.archlinux.org/title/Makepkg#Build_in_a_clean_chroot)
- [man: makechrootpkg(1)](https://man.archlinux.org/man/makechrootpkg.1)
- [man: arch-nspawn(1)](https://man.archlinux.org/man/arch-nspawn.1)
- [man: namcap(1)](https://man.archlinux.org/man/namcap.1)
- [Distrobox docs](https://github.com/89luca89/distrobox/blob/main/docs/README.md)
- [systemd-nspawn docs](https://www.freedesktop.org/software/systemd/man/latest/systemd-nspawn.html)
