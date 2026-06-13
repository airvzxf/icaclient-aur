#!/usr/bin/env bash
# test-variant.bash - Orchestrate testing of a PKGBUILD variant
# Usage: scripts/test-variant.bash <variant-name> [options]
#
# Layers (see docs/testing-infrastructure.md):
#   L0: namcap static analysis
#   L2: makechrootpkg clean build (default)
#   L3 (optional): GUI smoke test via distrobox / systemd-nspawn / podman
#
# Exit codes:
#   0 - success
#   1 - prerequisite failure, L0 error, or argument error
#   2 - L2 build failure
#   3 - L3 sandbox launch failure (currently unused; L3 uses exec so the sandbox
#       exit code propagates)
#
# sudo:
#   The script auto-detects whether sudo is passwordless for the specific
#   commands it needs (REQUIRED_CMDS, in scripts/lib/test-common.bash). If
#   passwordless, the script invokes sudo internally as needed. If not, the
#   script aborts with a clear message: either re-run with `sudo`, or add
#   a NOPASSWD line in /etc/sudoers for those commands. See
#   docs/testing-infrastructure.md for details.

set -euo pipefail

# Resolve the script's real path so that SCRIPT_DIR points at the repo's
# scripts/ directory even when the user invokes the script via a symlink
# from outside the repo. `BASH_SOURCE[0]` returns the path the user typed
# (e.g. /tmp/test-variant), so we resolve it through `readlink -f` (or
# fall back to `realpath`) to get the actual location before computing
# the directory.
#
# Why this matters: without the symlink resolution, `source` of the test
# helpers below would fail with "No such file or directory" because
# SCRIPT_DIR would point at the symlink's directory, not the real one.
if command -v readlink >/dev/null 2>&1; then
    SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
elif command -v realpath >/dev/null 2>&1; then
    SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
else
    SCRIPT_PATH="${BASH_SOURCE[0]}"
fi
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
# shellcheck source=scripts/lib/test-common.bash
source "${SCRIPT_DIR}/lib/test-common.bash"

# --- Defaults ---
VARIANT_NAME=""
CHROOT_DIR="${HOME}/.local/chroots/arch-citrix"
SANDBOX_MODE="none"
NO_BUILD=0
KEEP_CHROOT=0
NO_GPU=0
SMOKE_TEST=0
KEEP_RUNNING=0
USE_SUDO=""
STAGE_DIR=""
SMOKE_STAGING_DIR=""
SMOKE_DISTROBOX_DIR=""

# --- Cleanup trap ---
# Ensures STAGE_DIR (and any future transient state) is removed on any
# exit path (success, error, signal). The L3 sandbox launchers use `exec`,
# so they never reach this trap.
_cleanup() {
    local rc=$?
    if [[ -n "$STAGE_DIR" ]] && [[ -d "$STAGE_DIR" ]]; then
        rm -rf "$STAGE_DIR" 2>/dev/null || true
    fi
    if [[ -n "$SMOKE_STAGING_DIR" ]] && [[ -d "$SMOKE_STAGING_DIR" ]]; then
        rm -rf "$SMOKE_STAGING_DIR" 2>/dev/null || true
    fi
    if [[ -n "$SMOKE_DISTROBOX_DIR" ]] && [[ -d "$SMOKE_DISTROBOX_DIR" ]]; then
        rm -rf "$SMOKE_DISTROBOX_DIR" 2>/dev/null || true
    fi
    exit "$rc"
}
trap _cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

usage() {
    cat <<EOF
Usage: $(basename "$0") <variant-name> [options]

Orchestrate testing of a PKGBUILD variant under pkgbuilds/<variant-name>/.

Options:
  --sandbox=MODE       GUI smoke test sandbox: distrobox|nspawn|podman|none (default: none)
  --smoke-test         In L3, run automated S1/S2/S3 smoke test (library-level)
                       before exec-ing into the sandbox shell. Requires the
                       icaclient package to be installed inside the sandbox
                       (nspawn: done by L2; distrobox/podman: do 'makepkg -si'
                       first, then re-run with --smoke-test).
  --keep-running       With --smoke-test, leave wfica alive after S3 for visual
                       inspection of the "Connecting..." dialog instead of
                       killing it. selfservice is always killed at S1.
  --no-build           Skip L2 (only run L0 namcap)
  --chroot-dir=PATH    Chroot base directory (default: ~/.local/chroots/arch-citrix)
  --keep-chroot        Do not offer to clean up the chroot on exit
  --no-gpu             Do not pass /dev/dri to the sandbox
  -h, --help           Show this help

sudo:
  Auto-detected. If interactive, run as:  sudo $0 ...

Examples:
  $0 bundle-4.0-icu70
  $0 bundle-4.0-icu70 --sandbox=distrobox
  $0 bundle-4.0-icu70 --sandbox=nspawn --smoke-test
  $0 bundle-4.0-icu70 --sandbox=distrobox --smoke-test --keep-running
EOF
}

# --- Argument parsing ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --sandbox=*)
            SANDBOX_MODE="${1#*=}"
            if [[ -z "$SANDBOX_MODE" ]]; then
                die "--sandbox= requires a non-empty value (got empty). Try --help."
            fi
            shift
            ;;
        --sandbox)
            if [[ $# -lt 2 ]] || [[ -z "${2:-}" ]]; then
                die "--sandbox requires a value. Try --sandbox=distrobox|nspawn|podman|none"
            fi
            SANDBOX_MODE="$2"
            shift 2
            ;;
        --no-build)
            NO_BUILD=1
            shift
            ;;
        --chroot-dir=*)
            CHROOT_DIR="${1#*=}"
            if [[ -z "$CHROOT_DIR" ]]; then
                die "--chroot-dir= requires a non-empty value (got empty). Try --help."
            fi
            shift
            ;;
        --chroot-dir)
            if [[ $# -lt 2 ]] || [[ -z "${2:-}" ]]; then
                die "--chroot-dir requires a value. Try --chroot-dir=/path/to/chroots"
            fi
            CHROOT_DIR="$2"
            shift 2
            ;;
        --keep-chroot)
            KEEP_CHROOT=1
            shift
            ;;
        --no-gpu)
            NO_GPU=1
            shift
            ;;
        --smoke-test)
            SMOKE_TEST=1
            shift
            ;;
        --keep-running)
            KEEP_RUNNING=1
            shift
            ;;
        -*)
            die "Unknown option: $1. Try --help."
            ;;
        *)
            if [[ -z "$VARIANT_NAME" ]]; then
                VARIANT_NAME="$1"
            else
                die "Unexpected positional argument: $1"
            fi
            shift
            ;;
    esac
done

# --- Validate sandbox mode ---
case "$SANDBOX_MODE" in
    distrobox|nspawn|podman|none) ;;
    *)
        die "Invalid --sandbox mode: $SANDBOX_MODE (must be distrobox|nspawn|podman|none)"
        ;;
esac

# --- Validate flag combinations ---
# Catch obviously-wrong combinations early, before any expensive work (L2
# build can take 30-60s for the real icaclient tarball). Better to die
# immediately with a clear message.
if [[ $SMOKE_TEST -eq 1 ]] && [[ "$SANDBOX_MODE" == "none" ]]; then
    die "--smoke-test requires --sandbox=distrobox|nspawn|podman (the S1-S3 GUI scenarios need a display)"
fi
if [[ $KEEP_RUNNING -eq 1 ]] && [[ $SMOKE_TEST -eq 0 ]]; then
    die "--keep-running requires --smoke-test (wfica is only left alive during the S3 smoke test)"
fi

# --- Validate variant ---
[[ -n "$VARIANT_NAME" ]] || { usage; exit 1; }

# Derive REPO_ROOT from the script's own location, not from $PWD. The user
# may invoke the script from any directory (CI, a different worktree, a
# shell where they cd'd before running); the script always lives at
# <repo>/scripts/test-variant.bash, so the repo root is its parent.
# This also makes the script work when run as a symlink from outside the repo.
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VARIANT_DIR="${REPO_ROOT}/pkgbuilds/${VARIANT_NAME}"
PKGBUILD="${VARIANT_DIR}/PKGBUILD"

[[ -d "$VARIANT_DIR" ]] || die "Variant directory not found: $VARIANT_DIR"
[[ -f "$PKGBUILD" ]] || die "PKGBUILD not found at: $PKGBUILD"

# --- Pre-flight ---
log_phase "Pre-flight checks"
check_prereqs

# Determine sudo prefix
if [[ $EUID -eq 0 ]]; then
    USE_SUDO=""
    SUDO_MODE="root"
else
    SUDO_MODE="$(detect_sudo_mode)"
    case "$SUDO_MODE" in
        unavailable)
            die "sudo unavailable; install sudo and add your user to sudoers"
            ;;
        interactive)
            die "sudo needs a password for makechrootpkg/arch-nspawn. Either:
  1. Re-run with sudo:  sudo $0 ...
  2. Or add a NOPASSWD line to /etc/sudoers for: ${REQUIRED_CMDS[*]}
     (use 'sudo visudo' to edit; see docs/testing-infrastructure.md for details)"
            ;;
        passwordless)
            USE_SUDO="sudo"
            ;;
    esac
fi

# Detect host capabilities (run in the user env, not the chroot)
IFS=$'\t' read -r DISPLAY_TYPE DISPLAY_SOCKET < <(detect_display)
IFS=$'\t' read -r AUDIO_TYPE AUDIO_SOCKET < <(detect_audio)
GPU_TYPE="$(detect_gpu)"

log_info "Variant:           $VARIANT_NAME"
log_info "PKGBUILD:          $PKGBUILD"
log_info "Chroot dir:        $CHROOT_DIR"
log_info "Sandbox mode:      $SANDBOX_MODE"
log_info "Display:           $DISPLAY_TYPE (${DISPLAY_SOCKET:-no socket})"
log_info "Audio:             $AUDIO_TYPE (${AUDIO_SOCKET:-no socket})"
log_info "GPU:               $GPU_TYPE"
log_info "sudo mode:         $SUDO_MODE"
log_info "Running as:        $(id -un) (EUID=$EUID)"

# --- Phase 1: L0 namcap ---
log_phase "L0: Static lint (namcap)"
# namcap prints `E:` (error) and `W:` (warning) lines for problems in the
# PKGBUILD. Its exit code is unreliable: in practice it returns 0 for almost
# all cases except "file not found" / "Python traceback". We therefore
# (a) capture namcap's output, (b) display it, and (c) explicitly check for
# `E:` lines in the output. Treat any `E:` line as a hard failure (per the
# namcap(1) man page: "Errors are things that namcap is very sure are wrong
# and need to be fixed"). `W:` lines are warnings, expected for AUR
# packages, and are ignored.
NAMCAP_OUT="$(namcap "$PKGBUILD" 2>&1)" || NAMCAP_RC=$? || true
NAMCAP_RC=${NAMCAP_RC:-0}
if [[ -n "$NAMCAP_OUT" ]]; then
    printf '%s\n' "$NAMCAP_OUT" >&2
fi
if [[ $NAMCAP_RC -ne 0 ]]; then
    EXIT_CODE=1 die "namcap exited with non-zero status (rc=$NAMCAP_RC) on $PKGBUILD"
fi
if printf '%s\n' "$NAMCAP_OUT" | grep -qE '(^|[[:space:]])E:'; then
    EXIT_CODE=1 die "namcap reported errors on $PKGBUILD"
fi
log_info "namcap: OK (warnings are expected and ignored)"

if [[ $NO_BUILD -eq 1 ]]; then
    # Warn (not die) so a user who passed --smoke-test with --no-build by
    # mistake sees a clear message but the lint-only run still completes.
    if [[ $SMOKE_TEST -eq 1 ]]; then
        log_warn "--smoke-test has no effect with --no-build (L3 is skipped; re-run without --no-build to run the smoke test)"
    fi
    if [[ $KEEP_RUNNING -eq 1 ]]; then
        log_warn "--keep-running has no effect with --no-build (L3 is skipped)"
    fi
    log_info "--no-build set; skipping L2 and L3"
    log_info "Done (L0 only)."
    exit 0
fi

# --- Phase 2: L2 makechrootpkg ---
log_phase "L2: Clean build (makechrootpkg)"

CHROOT_ROOT="${CHROOT_DIR}/root"
if [[ ! -d "$CHROOT_ROOT" ]]; then
    log_info "Chroot not found at $CHROOT_ROOT."
    log_info "Creating (first-run downloads base + base-devel, ~2-3 GB)..."

    # mkarchroot needs a makepkg.conf to seed the chroot. If we passed
    # /dev/null (the default for "no file"), the chroot would have an empty
    # /etc/makepkg.conf and makepkg inside the chroot would fail with
    # "SRCEXT does not contain a valid package suffix". Use the host's
    # /etc/makepkg.conf so SRCEXT/PKGEXT/MAKEFLAGS are set correctly.
    MAKEPKG_CONF="/etc/makepkg.conf"
    if [[ ! -f "$MAKEPKG_CONF" ]]; then
        log_warn "Host $MAKEPKG_CONF not found; using /dev/null. The chroot's"
        log_warn "  /etc/makepkg.conf will be empty and the build will likely fail."
        MAKEPKG_CONF="/dev/null"
    fi

    mkdir -p "$CHROOT_DIR"
    $USE_SUDO mkarchroot -M "$MAKEPKG_CONF" "$CHROOT_ROOT" base-devel
fi

# Defensive: if the chroot's /etc/makepkg.conf is empty (which happens when
# mkarchroot was called with -M /dev/null, e.g., by older versions of this
# script), copy the host's /etc/makepkg.conf into the chroot so makepkg
# inside the chroot has SRCEXT/PKGEXT/MAKEFLAGS set.
if [[ -f /etc/makepkg.conf ]] \
    && ! $USE_SUDO arch-nspawn "$CHROOT_ROOT" test -s /etc/makepkg.conf 2>/dev/null; then
    log_info "Chroot's /etc/makepkg.conf is empty or missing; seeding from host."
    # The two /etc/makepkg.conf paths look the same but are different files
    # (host vs chroot). Shellcheck's SC2094 does not distinguish them.
    # shellcheck disable=SC2094
    $USE_SUDO arch-nspawn "$CHROOT_ROOT" tee /etc/makepkg.conf >/dev/null < /etc/makepkg.conf
fi

# Run the build
cd "$VARIANT_DIR"
START_TIME=$SECONDS
# Sanitize variant name for the log path: variant names with `/` (e.g. a
# nested pkgbuilds/group/name/ layout) would otherwise produce an invalid
# path like `/tmp/makepkg-build-group/name.log`. The directory component
# of the path must not exist, so we replace `/` with `-` (and strip any
# other characters that are illegal in filenames, just in case).
LOG_VARIANT_NAME="${VARIANT_NAME//\//-}"
LOG_VARIANT_NAME="${LOG_VARIANT_NAME// /_}"
BUILD_LOG="/tmp/makepkg-build-${LOG_VARIANT_NAME}.log"
if ! $USE_SUDO makechrootpkg -c -r "$CHROOT_DIR" -- --nocheck >"$BUILD_LOG" 2>&1; then
    log_warn "makechrootpkg failed. Last 40 lines of $BUILD_LOG:"
    tail -n 40 "$BUILD_LOG" >&2 || true
    EXIT_CODE=2 die "makechrootpkg failed."
fi
BUILD_DURATION=$((SECONDS - START_TIME))
log_info "Build completed in $(format_duration $BUILD_DURATION). Full log: $BUILD_LOG"

# --- Phase 3: Install in chroot + collect checklist outputs ---
log_phase "L2: Install in chroot and collect checklist outputs"

PKG_FILE=$(find "$VARIANT_DIR" -maxdepth 1 -name '*.pkg.tar.zst' -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr | head -n1 | cut -d' ' -f2-)
if [[ -z "$PKG_FILE" ]]; then
    EXIT_CODE=2 die "No .pkg.tar.zst file found in $VARIANT_DIR after build"
fi
log_info "Built package: $PKG_FILE"

# Install into the chroot by bind-mounting a staging dir. We do this
# (rather than `cp` into the chroot) because:
#   - The chroot's /tmp is owned by root, so a host `cp` needs sudo.
#   - `cp` is usually not in the user's NOPASSWD sudoers (only `mount`
#     and `umount` are, and they're a smaller surface to authorize).
#   - Bind mount + arch-nspawn pacman -U is the standard Arch pattern.
PKG_BASENAME=$(basename "$PKG_FILE")
# Install the package into the chroot. We use arch-nspawn's -f flag,
# which copies a file from the host into the chroot's filesystem
# (host-side `cp -T`, not an overlayfs write), then runs the chroot
# command.
#
# Why not /tmp? systemd-nspawn mounts a fresh tmpfs on /tmp at session
# start, so anything copied there is hidden inside the container. We use
# /opt/.citrix-test-stage instead, which lives on the chroot's persistent
# filesystem and is visible inside the nspawn session.
STAGE_DIR=$(mktemp -d /tmp/citrix-stage.XXXXXX)
cp "$PKG_FILE" "$STAGE_DIR/"
$USE_SUDO arch-nspawn \
    -f "$STAGE_DIR/$PKG_BASENAME:/opt/.citrix-test-stage/$PKG_BASENAME" \
    "$CHROOT_ROOT" pacman -U --noconfirm "/opt/.citrix-test-stage/$PKG_BASENAME"
$USE_SUDO arch-nspawn "$CHROOT_ROOT" rm -f "/opt/.citrix-test-stage/$PKG_BASENAME"
$USE_SUDO arch-nspawn "$CHROOT_ROOT" rmdir /opt/.citrix-test-stage 2>/dev/null || true
rm -rf "$STAGE_DIR"
log_info "Installed $PKG_BASENAME into chroot"

# Collect the 4 chroot-side outputs from TESTING.md's Local checklist.
# The 5th (journalctl) is host-side and is the tester's responsibility.
log_info "---"
log_info "Checklist outputs (paste these into the test report):"
log_info "---"

echo
echo "## pacman -Q | grep -iE 'webkit|soup|patchelf' (inside chroot):"
$USE_SUDO arch-nspawn "$CHROOT_ROOT" /bin/bash -c '
    pacman -Q | grep -iE "webkit|soup|patchelf" || echo "(no matches)"
'

echo
echo "## readelf -d /opt/Citrix/ICAClient/selfservice | grep -E 'RUNPATH|RPATH|NEEDED':"
$USE_SUDO arch-nspawn "$CHROOT_ROOT" /bin/bash -c '
    if [ -f /opt/Citrix/ICAClient/selfservice ]; then
        readelf -d /opt/Citrix/ICAClient/selfservice | grep -E "RUNPATH|RPATH|NEEDED" || echo "(no RUNPATH/RPATH/NEEDED entries)"
    else
        echo "(/opt/Citrix/ICAClient/selfservice not found in chroot - the package did not install it)"
    fi
'

echo
echo "## ldd /opt/Citrix/ICAClient/selfservice | grep -iE 'not found|webkit|soup':"
$USE_SUDO arch-nspawn "$CHROOT_ROOT" /bin/bash -c '
    if [ -f /opt/Citrix/ICAClient/selfservice ]; then
        ldd /opt/Citrix/ICAClient/selfservice | grep -iE "not found|webkit|soup" || echo "(all resolved)"
    else
        echo "(/opt/Citrix/ICAClient/selfservice not found in chroot)"
    fi
'

echo
echo "## time makepkg -sf 2>&1 | tail -30:  (already done; duration: $(format_duration $BUILD_DURATION))"
echo "  See $BUILD_LOG for the full output."

echo
echo "## journalctl (host-side, run on the host manually, not in this script):"
echo "  journalctl --user -xe | grep -i citrix"
echo "  journalctl -xe | grep -i citrix"
log_info "---"

# --- Smoke test staging ---
# Populates two host-side directories with the same content (the smoke
# library, the run-smoke.bash driver, and the .ica fixtures):
#   SMOKE_STAGING_DIR    bind-mount source for nspawn / podman
#   SMOKE_DISTROBOX_DIR  $XDG_CACHE_HOME path, auto-shared with distrobox
#                        (distrobox maps the host's $HOME into the
#                        container; $XDG_CACHE_HOME defaults to
#                        $HOME/.cache and is also mapped).
#
# Called once, just before the L3 phase, only when --smoke-test is set.
_stage_smoke_test() {
    local repo_fixtures="${REPO_ROOT}/scripts/test-fixtures"
    local repo_smoke_lib="${SCRIPT_DIR}/lib/citrix-smoke.bash"

    if ! [[ -d "$repo_fixtures" ]]; then
        die "Smoke test fixtures dir not found: $repo_fixtures"
    fi
    if ! [[ -f "$repo_smoke_lib" ]]; then
        die "Smoke test library not found: $repo_smoke_lib"
    fi

    # Host-side staging dir for nspawn / podman bind-mounts. /tmp because
    # the bind-mount target (/opt/citrix-smoke/) is on the chroot's root
    # filesystem and we want the staging to be invisible to the host user
    # outside the script.
    SMOKE_STAGING_DIR="$(mktemp -d /tmp/citrix-smoke-staging.XXXXXX)"
    cp "$repo_fixtures"/* "$SMOKE_STAGING_DIR/"
    cp "$repo_smoke_lib" "$SMOKE_STAGING_DIR/"
    chmod +x "$SMOKE_STAGING_DIR/run-smoke.bash"

    # Distrobox-shared dir. distrobox's default --additional-flags sets
    # up bind mounts for $HOME and the XDG dirs, so the staging is
    # visible inside the container at the same path.
    local xdg_cache="${XDG_CACHE_HOME:-$HOME/.cache}"
    SMOKE_DISTROBOX_DIR="${xdg_cache}/citrix-smoke-staging"
    mkdir -p "$SMOKE_DISTROBOX_DIR"
    cp "$SMOKE_STAGING_DIR"/* "$SMOKE_DISTROBOX_DIR/"
    chmod +x "$SMOKE_DISTROBOX_DIR/run-smoke.bash"

    log_info "Smoke test staged:"
    log_info "  bind-mount (nspawn/podman): $SMOKE_STAGING_DIR -> /opt/citrix-smoke/"
    log_info "  distrobox-shared:          $SMOKE_DISTROBOX_DIR"
}

# --- Sandbox launcher functions ---
# Defined before the L3 call site so the function names are visible to
# static analyzers and to the reader. The launchers themselves use `exec`,
# so the calling shell never returns from a successful launch.

# Clean up smoke test staging directories. The EXIT trap is supposed to
# do this, but `exec` in the L3 launchers replaces the shell and bypasses
# EXIT traps. So we explicitly call this helper just before each `exec`.
#
# The L3 launchers' interactive `exec` invocation does NOT include the
# smoke-test mount (each launcher keeps it in a separate local array that
# is only used for the smoke-test subprocess), so removing the staging
# dir here is safe — the second `arch-nspawn` / `podman run` /
# `distrobox enter` invocation has no stale references to it.
_cleanup_smoke_staging() {
    if [[ -n "$SMOKE_STAGING_DIR" ]] && [[ -d "$SMOKE_STAGING_DIR" ]]; then
        rm -rf "$SMOKE_STAGING_DIR" 2>/dev/null || true
    fi
    SMOKE_STAGING_DIR=""
    # SMOKE_DISTROBOX_DIR lives under $XDG_CACHE_HOME; clean it up too so
    # successive runs do not accumulate stale copies. Re-staging is cheap.
    if [[ -n "$SMOKE_DISTROBOX_DIR" ]] && [[ -d "$SMOKE_DISTROBOX_DIR" ]]; then
        rm -rf "$SMOKE_DISTROBOX_DIR" 2>/dev/null || true
    fi
    SMOKE_DISTROBOX_DIR=""
}

_enter_distrobox() {
    if ! command -v distrobox >/dev/null 2>&1; then
        die "distrobox not found. Install from AUR or Flatpak."
    fi

    log_info "Creating distrobox 'citrix-test' if it does not exist..."
    if ! distrobox list 2>/dev/null | grep -q '^citrix-test\b'; then
        local create_args=(--image archlinux:latest --name citrix-test)
        if [[ "$GPU_TYPE" == "nvidia" ]] && [[ $NO_GPU -eq 0 ]]; then
            create_args+=(--nvidia)
        fi
        distrobox create "${create_args[@]}"
    else
        log_info "(distrobox citrix-test already exists; reusing)"
        if [[ "$GPU_TYPE" == "nvidia" ]] && [[ $NO_GPU -eq 0 ]]; then
            log_warn "Host has NVIDIA but the existing distrobox may not have --nvidia."
            log_warn "  Re-create with: distrobox rm citrix-test && distrobox create --nvidia ..."
        fi
    fi

    log_info "Entering distrobox. Once inside, run:"
    log_info "  cd /tmp && git clone <your-fork-or-local-path> icaclient-aur"
    log_info "  cd icaclient-aur/pkgbuilds/$VARIANT_NAME"
    log_info "  makepkg -si"
    log_info "  /opt/Citrix/ICAClient/selfservice"
    log_info "  /opt/Citrix/ICAClient/wfica /path/to/some.ica   # S2"

    if [[ $SMOKE_TEST -eq 1 ]]; then
        local keep_arg="no"
        [[ $KEEP_RUNNING -eq 1 ]] && keep_arg="yes"
        log_phase "L3: S1-S3 smoke test (in distrobox)"
        local smoke_exit=0
        distrobox enter citrix-test -- \
            bash "${SMOKE_DISTROBOX_DIR}/run-smoke.bash" "$keep_arg" || smoke_exit=$?
        if [[ $smoke_exit -ne 0 ]]; then
            log_warn "Smoke test reported failures (exit $smoke_exit). See [smoke] lines above."
        else
            log_info "Smoke test passed."
        fi
    fi

    _cleanup_smoke_staging
    exec distrobox enter citrix-test
}

_enter_nspawn() {
    local bind_args=()
    local setenv_args=()

    # Display
    if [[ "$DISPLAY_TYPE" == "x11" ]]; then
        bind_args+=(--bind=/tmp/.X11-unix)
        setenv_args+=(--setenv=DISPLAY="$DISPLAY")
        [[ -n "${XAUTHORITY:-}" ]] && setenv_args+=(--setenv=XAUTHORITY="$XAUTHORITY")
    else
        bind_args+=(--bind-ro="$XDG_RUNTIME_DIR")
        setenv_args+=(--setenv=WAYLAND_DISPLAY="$WAYLAND_DISPLAY")
        setenv_args+=(--setenv=XDG_RUNTIME_DIR="/run/user/host-$(id -u)")
    fi

    # Audio
    if [[ "$AUDIO_TYPE" == "pulse" ]] || [[ "$AUDIO_TYPE" == "pipewire" ]]; then
        bind_args+=(--bind="$XDG_RUNTIME_DIR/pulse")
        setenv_args+=(--setenv=PULSE_SERVER="unix:/run/user/host-$(id -u)/pulse/native")
    fi

    # D-Bus session bus
    if [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
        setenv_args+=(--setenv=DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS")
    fi

    # makepkg cache so we do not re-download the tarball inside the chroot
    [[ -d "$HOME/.cache/makepkg" ]] && bind_args+=(--bind-ro="$HOME/.cache/makepkg")

    # GPU
    if [[ "$GPU_TYPE" != "none" ]] && [[ $NO_GPU -eq 0 ]]; then
        if [[ "$GPU_TYPE" == "nvidia" ]]; then
            # systemd-nspawn 260.2-2-arch (the build host) does NOT support
            # the --device= option (verified: it is not listed in --help
            # and is rejected with "unrecognized option"). The bind-mount
            # fallback works on every systemd-nspawn version. The device
            # file is bind-mounted in (so the chroot can open it), and
            # the runtime env vars below tell GL/Vulkan to use the GPU.
            bind_args+=(--bind=/dev/nvidia0)
            bind_args+=(--bind=/dev/nvidiactl)
            bind_args+=(--bind=/dev/nvidia-uvm)
            setenv_args+=(--setenv=LIBGL_ALWAYS_SOFTWARE=0)
            setenv_args+=(--setenv=NVIDIA_DRIVER_CAPABILITIES=all)
        else
            # Intel/AMD: same fallback reasoning as the NVIDIA branch.
            # --device= is unsupported on this systemd-nspawn; --bind=
            # achieves the same effect.
            bind_args+=(--bind=/dev/dri)
        fi
    fi

    log_info "Entering systemd-nspawn chroot with GUI forwarding."
    log_info "  mounts: ${bind_args[*]}"
    log_info "  env:    ${setenv_args[*]}"
    log_info "Once inside, run:"
    log_info "  cd /tmp/build"
    log_info "  cp -r /path/to/icaclient-aur/pkgbuilds/$VARIANT_NAME ."
    log_info "  cd $VARIANT_NAME && makepkg -si"
    log_info "  /opt/Citrix/ICAClient/selfservice"
    log_info "  /opt/Citrix/ICAClient/wfica /path/to/some.ica   # S2"

    if [[ $SMOKE_TEST -eq 1 ]]; then
        # Bind-mount the smoke-test staging read-only into the chroot at
        # /opt/citrix-smoke/. The driver runs at /opt/citrix-smoke/run-smoke.bash.
        # Note: --bind-ro= is itself read-only; do NOT append ":ro" (that
        # would be parsed as a separate, invalid option).
        #
        # IMPORTANT: keep the smoke-test mount in a SEPARATE array (not in
        # bind_args). The cleanup helper (_cleanup_smoke_staging) is called
        # before the exec'd interactive shell below, which would remove the
        # staging dir; if bind_args still referenced it, the second
        # arch-nspawn invocation would fail with "Failed to clone <staging>:
        # No such file or directory".
        local smoke_bind_args=(--bind-ro="$SMOKE_STAGING_DIR:/opt/citrix-smoke")
        local keep_arg="no"
        [[ $KEEP_RUNNING -eq 1 ]] && keep_arg="yes"
        log_phase "L3: S1-S3 smoke test (in nspawn)"
        local smoke_exit=0
        $USE_SUDO arch-nspawn "$CHROOT_ROOT" "${bind_args[@]}" "${smoke_bind_args[@]}" "${setenv_args[@]}" \
            bash /opt/citrix-smoke/run-smoke.bash "$keep_arg" || smoke_exit=$?
        if [[ $smoke_exit -ne 0 ]]; then
            log_warn "Smoke test reported failures (exit $smoke_exit). See [smoke] lines above."
        else
            log_info "Smoke test passed."
        fi
    fi

    # arch-nspawn takes the working directory as a POSITIONAL argument
    # (it does NOT accept systemd-nspawn's -D / --directory flag; the dir is
    # positional and the rest is forwarded to systemd-nspawn as-is).
    #
    # Note: bind_args does NOT include the smoke-test mount (see above).
    # _cleanup_smoke_staging can therefore safely remove the staging dir
    # before this exec; the second arch-nspawn invocation has no stale
    # bind-mount references.
    _cleanup_smoke_staging
    exec $USE_SUDO arch-nspawn "$CHROOT_ROOT" "${bind_args[@]}" "${setenv_args[@]}" /bin/bash
}

_enter_podman() {
    if ! command -v podman >/dev/null 2>&1; then
        die "podman not found. Install from [extra]."
    fi

    local volume_args=()
    local env_args=()
    local device_args=()

    # Display
    if [[ "$DISPLAY_TYPE" == "x11" ]]; then
        volume_args+=(-v /tmp/.X11-unix:/tmp/.X11-unix:Z)
        env_args+=(-e DISPLAY="$DISPLAY")
        [[ -n "${XAUTHORITY:-}" ]] && env_args+=(-e XAUTHORITY="$XAUTHORITY")
    else
        volume_args+=(-v "$XDG_RUNTIME_DIR:/run/user/1000:Z")
        env_args+=(-e WAYLAND_DISPLAY="$WAYLAND_DISPLAY")
        env_args+=(-e XDG_RUNTIME_DIR=/run/user/1000)
    fi

    # Audio
    if [[ "$AUDIO_TYPE" == "pulse" ]] || [[ "$AUDIO_TYPE" == "pipewire" ]]; then
        volume_args+=(-v "$XDG_RUNTIME_DIR/pulse:/run/user/1000/pulse:Z")
        env_args+=(-e PULSE_SERVER=unix:/run/user/1000/pulse/native)
    fi

    # makepkg cache
    [[ -d "$HOME/.cache/makepkg" ]] && volume_args+=(-v "$HOME/.cache/makepkg:/root/.cache/makepkg:Z")

    # GPU (Intel/AMD only; NVIDIA needs nvidia-container-toolkit hooks)
    if [[ "$GPU_TYPE" == "intel-or-amd" ]] && [[ $NO_GPU -eq 0 ]]; then
        device_args+=(--device /dev/dri)
    fi

    log_info "Launching podman container with GUI forwarding."
    log_info "  volumes: ${volume_args[*]}"
    log_info "  env:     ${env_args[*]}"
    log_info "  devices: ${device_args[*]}"
    log_info "Once inside, run:"
    log_info "  cd /tmp && git clone <your-fork-or-local-path> icaclient-aur"
    log_info "  cd icaclient-aur/pkgbuilds/$VARIANT_NAME"
    log_info "  makepkg -si"
    log_info "  /opt/Citrix/ICAClient/selfservice"
    log_info "  /opt/Citrix/ICAClient/wfica /path/to/some.ica   # S2"

    if [[ $SMOKE_TEST -eq 1 ]]; then
        # IMPORTANT: keep the smoke-test bind in a SEPARATE array (not in
        # volume_args). The cleanup helper (_cleanup_smoke_staging) is called
        # before the exec'd interactive shell below, which would remove the
        # staging dir; if volume_args still referenced it, the second
        # `podman run` invocation would fail with
        # "Error: statfs <staging>: no such file or directory".
        local smoke_volume_args=(-v "$SMOKE_STAGING_DIR:/opt/citrix-smoke:ro")
        local keep_arg="no"
        [[ $KEEP_RUNNING -eq 1 ]] && keep_arg="yes"
        log_phase "L3: S1-S3 smoke test (in podman)"
        local smoke_exit=0
        podman run --rm \
            "${env_args[@]}" \
            "${volume_args[@]}" \
            "${smoke_volume_args[@]}" \
            --security-opt label=type:container_file_t \
            --userns=keep-id \
            "${device_args[@]}" \
            archlinux:latest \
            bash /opt/citrix-smoke/run-smoke.bash "$keep_arg" || smoke_exit=$?
        if [[ $smoke_exit -ne 0 ]]; then
            log_warn "Smoke test reported failures (exit $smoke_exit). See [smoke] lines above."
        else
            log_info "Smoke test passed."
        fi
    fi

    # Note: volume_args does NOT include the smoke-test bind (see above).
    # _cleanup_smoke_staging can therefore safely remove the staging dir
    # before this exec; the second `podman run` invocation has no stale
    # volume references.
    _cleanup_smoke_staging
    exec podman run -it --rm \
        "${env_args[@]}" \
        "${volume_args[@]}" \
        --security-opt label=type:container_file_t \
        --userns=keep-id \
        "${device_args[@]}" \
        archlinux:latest \
        /bin/bash
}

# --- Summary + cleanup hint (printed BEFORE L3 launchers, since the launchers
#     use `exec` and the summary would never be seen otherwise) ---
log_phase "Summary"
if [[ $SMOKE_TEST -eq 1 ]]; then
    log_info "S1 (selfservice launches)        : automated by --smoke-test (library check)"
    log_info "S2 (wfica opens .ica)            : automated by --smoke-test (library check)"
    log_info "S3 (wfica Connecting dialog)     : automated by --smoke-test (library check)"
    if [[ $KEEP_RUNNING -eq 1 ]]; then
        log_info "                                   wfica will be left alive for visual inspection"
    fi
else
    log_info "S1 (selfservice launches)        : run --sandbox=... to validate by eye"
    log_info "S2 (wfica opens .ica)            : run --sandbox=... to validate by eye"
    log_info "S3 (wfica Connecting dialog)     : run --sandbox=... to validate by eye"
    log_info "                                   (add --smoke-test to automate the library-level checks)"
fi
log_info "S4 (install without AUR webkit)  : the chroot is clean, no AUR; verified above"
log_info "S5 (build time)                  : $(format_duration $BUILD_DURATION) (target <5m, ceiling <15m)"
log_info "S6 (real Citrix session)         : connect to your farm, then run journalctl on the host"
log_info "S7 (no new system deps)          : check host with 'pacman -Qe' before/after install"
log_info ""
log_info "Next: open a Test report issue using .github/ISSUE_TEMPLATE/test-report.md"
log_info "      and paste the 4 chroot-side outputs above into it."

# Always show where the chroot lives (informational, useful in either case).
# Only suppress the "To remove it manually" hint when the user passed
# --keep-chroot (signaling "I'm keeping it on purpose").
log_info "Chroot preserved at: $CHROOT_DIR"
if [[ $KEEP_CHROOT -eq 0 ]]; then
    log_info "To remove it manually: $USE_SUDO rm -rf $CHROOT_DIR"
fi

# --- Phase 4: L3 GUI smoke test (optional) ---
# The L3 launchers (defined above) use `exec`, so this block is only reached
# when SANDBOX_MODE is "none". When the launcher runs, the script is replaced
# by the sandbox shell and never returns.
if [[ "$SANDBOX_MODE" != "none" ]]; then
    log_phase "L3: GUI smoke test ($SANDBOX_MODE)"

    if [[ "$DISPLAY_TYPE" == "none" ]]; then
        die "No display server detected on host; cannot run L3 GUI smoke test"
    fi
    if [[ "$SANDBOX_MODE" == "podman" ]] && [[ "$GPU_TYPE" == "nvidia" ]] && [[ $NO_GPU -eq 0 ]]; then
        log_warn "Podman with NVIDIA needs nvidia-container-toolkit; passthrough may not work."
        log_warn "  hint: install nvidia-container-toolkit or re-run with --no-gpu"
    fi

    # Stage smoke test fixtures (no-op if --smoke-test was not set; the
    # L3 launchers read SMOKE_STAGING_DIR / SMOKE_DISTROBOX_DIR).
    if [[ $SMOKE_TEST -eq 1 ]]; then
        _stage_smoke_test
    fi

    case "$SANDBOX_MODE" in
        distrobox)
            _enter_distrobox
            ;;
        nspawn)
            _enter_nspawn
            ;;
        podman)
            _enter_podman
            ;;
    esac
else
    # --smoke-test is validated at the top of the script (it requires a
    # non-"none" --sandbox), so reaching this branch with SMOKE_TEST=1
    # cannot happen. Just print the success line.
    log_info "Done."
fi
