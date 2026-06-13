#!/usr/bin/env bash
# test-common.bash - Shared functions for scripts/test-variant.bash
#
# This file is sourced, not executed. It provides:
#   - logging helpers (log_phase, log_info, log_warn, die)
#   - host environment detection (display, audio, GPU, sudo)
#   - prerequisite verification
#   - small utilities (require_cmd, format_duration)

# Guard against double-sourcing
if [[ -n "${TEST_COMMON_LOADED:-}" ]]; then
    return 0
fi
TEST_COMMON_LOADED=1

# --- Logging ---

_log() {
    local level="$1"
    shift
    printf '[%s] %s\n' "$level" "$*" >&2
}

log_phase() {
    _log "PHASE" "$*"
}

log_info() {
    _log "INFO " "$*"
}

log_warn() {
    _log "WARN " "$*"
}

die() {
    _log "FATAL" "$*"
    exit "${EXIT_CODE:-1}"
}

# --- Host environment detection ---
# Each function prints a TAB-separated pair on stdout: "<type>\t<socket>".
# For "none" types, the socket field is empty. The caller captures both
# values with `IFS=$'\t' read -r TYPE SOCKET < <(detect_xxx)`.
#
# Why not a side-effect variable? Because `$(detect_xxx)` runs the function
# in a subshell; any variable it sets is discarded when the subshell exits.
# Putting the data on stdout (consumed via process substitution) keeps the
# data flow explicit and subshell-safe.

detect_display() {
    if [[ -n "${WAYLAND_DISPLAY:-}" ]] && [[ -S "${XDG_RUNTIME_DIR:-}/$WAYLAND_DISPLAY" ]]; then
        printf 'wayland\t%s\n' "${XDG_RUNTIME_DIR}/$WAYLAND_DISPLAY"
    elif [[ -n "${DISPLAY:-}" ]] && [[ -S "/tmp/.X11-unix/X${DISPLAY#:}" ]]; then
        printf 'x11\t%s\n' "/tmp/.X11-unix/X${DISPLAY#:}"
    else
        printf 'none\t\n'
    fi
}

detect_audio() {
    if [[ -S "${XDG_RUNTIME_DIR:-}/pipewire-0" ]]; then
        printf 'pipewire\t%s\n' "${XDG_RUNTIME_DIR}/pipewire-0"
    elif [[ -S "${XDG_RUNTIME_DIR:-}/pulse/native" ]]; then
        printf 'pulse\t%s\n' "${XDG_RUNTIME_DIR}/pulse/native"
    else
        printf 'none\t\n'
    fi
}

detect_gpu() {
    if [[ ! -d /dev/dri ]]; then
        printf 'none\n'
        return
    fi
    if lsmod 2>/dev/null | grep -q nvidia; then
        printf 'nvidia\n'
    elif [[ -e /dev/dri/renderD128 ]]; then
        printf 'intel-or-amd\n'
    else
        printf 'none\n'
    fi
}

# Returns "passwordless", "interactive", or "unavailable" on stdout.
#
# Checks the user's sudoers for NOPASSWD rules on the specific commands
# the script needs (REQUIRED_CMDS). This is more accurate than testing
# `sudo -n true` (which would fail if the user only has NOPASSWD for our
# specific commands, not for `true`).
detect_sudo_mode() {
    if ! command -v sudo >/dev/null 2>&1; then
        printf 'unavailable\n'
        return
    fi
    # sudo -n -l lists what the user can run without a password.
    # If the user has any NOPASSWD rule for one of our commands, the
    # script can use sudo internally without prompting.
    if sudo -n -l 2>/dev/null | grep -qE 'NOPASSWD:.*\b('"$(IFS='|'; echo "${REQUIRED_CMDS[*]}")"')\b'; then
        printf 'passwordless\n'
    else
        printf 'interactive\n'
    fi
}

# --- Prerequisite verification ---

REQUIRED_CMDS=(
    namcap
    makechrootpkg
    arch-nspawn
    mkarchroot
    sudo
    pacman
)

check_prereqs() {
    local missing=()
    local cmd
    for cmd in "${REQUIRED_CMDS[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if (( ${#missing[@]} > 0 )); then
        log_warn "Missing required commands: ${missing[*]}"
        log_warn "Install 'devtools' and 'namcap' from [extra]:"
        log_warn "  sudo pacman -S devtools namcap"
        die "Prerequisites not met. See warnings above."
    fi

    local sudo_mode
    sudo_mode="$(detect_sudo_mode)"
    case "$sudo_mode" in
        unavailable)
            die "sudo is required for makechrootpkg/arch-nspawn. Install sudo and ensure your user is in sudoers."
            ;;
        passwordless)
            log_info "sudo mode: passwordless (NOPASSWD rule detected)"
            ;;
        interactive)
            log_warn "sudo mode: interactive (you may be prompted for password the first time)"
            log_warn "  hint: add a NOPASSWD line to /etc/sudoers for: ${REQUIRED_CMDS[*]}"
            ;;
    esac
}

require_cmd() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 \
        || die "Required command not found: $cmd"
}

# --- Utilities ---

# format_duration <seconds> -> "M:SS"
format_duration() {
    local secs="${1:-0}"
    printf '%d:%02d' $((secs / 60)) $((secs % 60))
}
