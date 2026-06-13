#!/usr/bin/env bash
# test-l3-args.bash - Test the L3 launcher argument assembly.
#
# The variables in setup() (VARIANT_NAME, CHROOT_ROOT, GPU_TYPE, etc.) are
# read by the L3 launcher bodies via eval; shellcheck can't follow that, so
# we disable the SC2034 (unused) check for them. fake_exec and
# _cleanup_smoke_staging are called from the eval'd launcher bodies, not
# directly, so SC2329 is also disabled.
# shellcheck disable=SC2034,SC2329
#
# This script validates that the L3 launchers (_enter_distrobox, _enter_nspawn,
# _enter_podman) in scripts/test-variant.bash assemble the correct bind args,
# setenv args, volume args, and device args for various host configurations.
#
# Approach:
# - Put fake binaries (distrobox, arch-nspawn, podman) in PATH that log their
#   invocations to a file. The arch-nspawn fake detects L2 invocations
#   (which use -f) and forwards them to the real arch-nspawn; for L3
#   invocations (which include --bind= or /opt/citrix-smoke) it just logs
#   and exits 0.
# - Extract the L3 launcher function bodies from test-variant.bash, strip
#   the definition + closing brace, replace `exec` with a recording
#   function (`fake_exec`), and eval them in a controlled environment.
# - Verify the fake-binary calls (in the FAKE_CALLS log) and the in-process
#   fake_exec calls (in EXEC_LOG) match the expected patterns for each
#   (display, audio, gpu, no-gpu, smoke-test) configuration.
set -uo pipefail

# Resolve our own dir for cleanup
TEST_DIR="$(mktemp -d /tmp/l3-test.XXXXXX)"
trap 'rm -rf "$TEST_DIR" "$FAKE_BIN_DIR" /tmp/l3-fake-bin.* /tmp/l3-fake-log.* /tmp/l3-fake-calls.* 2>/dev/null' EXIT

REPO_DIR="/home/wolf/workspace/projects/icaclient-aur"
TEST_VARIANT="${REPO_DIR}/scripts/test-variant.bash"

# Source test-common.bash (provides log_info, etc.)
# shellcheck source=scripts/lib/test-common.bash
source "${REPO_DIR}/scripts/lib/test-common.bash"

# --- Result tracking ---
PASS_COUNT=0
FAIL_COUNT=0
FAILED_TESTS=()

_pass() { printf '[PASS] %s\n' "$*"; PASS_COUNT=$((PASS_COUNT+1)); }
_fail() { printf '[FAIL] %s\n' "$*"; FAIL_COUNT=$((FAIL_COUNT+1)); FAILED_TESTS+=("$*"); }
_info() { printf '[INFO] %s\n' "$*"; }

# --- Build a fake-bin dir with smart fake binaries ---
FAKE_BIN_DIR="$(mktemp -d /tmp/l3-fake-bin.XXXXXX)"
export FAKE_BIN_DIR

# FAKE_LOG: human-readable log of all fake invocations
FAKE_LOG="$(mktemp /tmp/l3-fake-log.XXXXXX)"
export FAKE_LOG
_info "FAKE_LOG=$FAKE_LOG"

# FAKE_CALLS: machine-parseable log, one call per line, "binary\targ1\targ2\t..."
FAKE_CALLS="$(mktemp /tmp/l3-fake-calls.XXXXXX)"
export FAKE_CALLS
_info "FAKE_CALLS=$FAKE_CALLS"

# Add fake-bin to PATH so the L3 launchers' external commands hit our fakes.
export PATH="$FAKE_BIN_DIR:$PATH"

# Generic fake for arch-nspawn, podman. Logs args and records the call.
cat > "$FAKE_BIN_DIR/_fake_simple" <<'EOF'
#!/usr/bin/env bash
echo "FAKE($(basename "$0")) argc=$#:" >> "$FAKE_LOG"
i=0
for arg in "$@"; do
    echo "FAKE($(basename "$0")) argv[$i]=<$arg>" >> "$FAKE_LOG"
    i=$((i+1))
done
printf '%s' "$(basename "$0")" >> "$FAKE_CALLS"
printf '\t%s' "$@" >> "$FAKE_CALLS"
printf '\n' >> "$FAKE_CALLS"
exit 0
EOF
chmod +x "$FAKE_BIN_DIR/_fake_simple"

# distrobox fake: `distrobox list` returns empty (no citrix-test exists) so
# the create path is always taken.
cat > "$FAKE_BIN_DIR/distrobox" <<'EOF'
#!/usr/bin/env bash
echo "FAKE(distrobox) argc=$#:" >> "$FAKE_LOG"
i=0
for arg in "$@"; do
    echo "FAKE(distrobox) argv[$i]=<$arg>" >> "$FAKE_LOG"
    i=$((i+1))
done

if [[ "$1" == "list" ]]; then
    # No existing distroboxes
    exit 0
fi

printf '%s' "$(basename "$0")" >> "$FAKE_CALLS"
printf '\t%s' "$@" >> "$FAKE_CALLS"
printf '\n' >> "$FAKE_CALLS"
exit 0
EOF
chmod +x "$FAKE_BIN_DIR/distrobox"

# podman fake: just logs and records
ln -sf "$FAKE_BIN_DIR/_fake_simple" "$FAKE_BIN_DIR/podman"

# arch-nspawn fake: smart enough to forward L2 calls to the real arch-nspawn.
cat > "$FAKE_BIN_DIR/arch-nspawn" <<'EOF'
#!/usr/bin/env bash
echo "FAKE(arch-nspawn) argc=$#:" >> "$FAKE_LOG"
i=0
for arg in "$@"; do
    echo "FAKE(arch-nspawn) argv[$i]=<$arg>" >> "$FAKE_LOG"
    i=$((i+1))
done

# Detect L3 vs L2: L3 has --bind=, --bind-ro=, or /opt/citrix-smoke.
# L2 has -f or no --bind= at all.
is_l3=0
for arg in "$@"; do
    if [[ "$arg" == --bind=* ]] || [[ "$arg" == --bind-ro=* ]] || [[ "$arg" == *"/opt/citrix-smoke"* ]]; then
        is_l3=1
        break
    fi
done

if [[ $is_l3 -eq 1 ]]; then
    echo "FAKE(arch-nspawn) detected L3, recording + exit 0" >> "$FAKE_LOG"
    printf '%s' "$(basename "$0")" >> "$FAKE_CALLS"
    printf '\t%s' "$@" >> "$FAKE_CALLS"
    printf '\n' >> "$FAKE_CALLS"
    exit 0
fi

echo "FAKE(arch-nspawn) detected L2, passing through to real" >> "$FAKE_LOG"
exec /usr/bin/arch-nspawn "$@"
EOF
chmod +x "$FAKE_BIN_DIR/arch-nspawn"

# --- Extract launcher function bodies from test-variant.bash ---
_extract_func() {
    local fname="$1"
    python3 -c "
import sys
target = sys.argv[1]
path = sys.argv[2]
in_func = False
brace = 0
with open(path) as f:
    for line in f:
        if not in_func:
            if line.startswith(target + '()'):
                in_func = True
                brace = 0
                sys.stdout.write(line)
                for c in line:
                    if c == '{': brace += 1
                    elif c == '}': brace -= 1
                if brace == 0 and line.rstrip().endswith('}'):
                    break
                continue
        if in_func:
            sys.stdout.write(line)
            for c in line:
                if c == '{': brace += 1
                elif c == '}': brace -= 1
            if brace == 0:
                break
" "$fname" "$TEST_VARIANT"
}

DISTROBOX_BODY="$(_extract_func _enter_distrobox)"
NSPAWN_BODY="$(_extract_func _enter_nspawn)"
PODMAN_BODY="$(_extract_func _enter_podman)"

if [[ -z "$DISTROBOX_BODY" ]] || [[ -z "$NSPAWN_BODY" ]] || [[ -z "$PODMAN_BODY" ]]; then
    _fail "Could not extract launcher function bodies from $TEST_VARIANT"
    exit 1
fi

# Strip the function definition and closing brace, rename the function,
# and replace `exec` with `fake_exec` (a recording function in this script).
_strip_and_rename() {
    local body="$1"
    local newname="$2"
    body="${body#*\{}"
    body="${body%\}}"
    body="${body//exec /fake_exec }"
    printf '%s() {\n%s\n}\n' "$newname" "$body"
}

DISTROBOX_BODY_EVAL="$(_strip_and_rename "$DISTROBOX_BODY" run_distrobox_test)"
NSPAWN_BODY_EVAL="$(_strip_and_rename "$NSPAWN_BODY" run_nspawn_test)"
PODMAN_BODY_EVAL="$(_strip_and_rename "$PODMAN_BODY" run_podman_test)"

# --- Test environment setup ---
EXEC_LOG=()
fake_exec() {
    EXEC_LOG+=("$*")
}
_cleanup_smoke_staging() {
    :  # no-op in the test
}

setup() {
    local display_type="$1"
    local audio_type="$2"
    local gpu_type="$3"
    local no_gpu="$4"
    local smoke_test="${5:-0}"
    local keep_running="${6:-0}"

    EXEC_LOG=()
    VARIANT_NAME="test-variant"
    CHROOT_DIR="/tmp/test-chroot"
    CHROOT_ROOT="/tmp/test-chroot/root"
    DISPLAY_TYPE="$display_type"
    DISPLAY_SOCKET=""
    AUDIO_TYPE="$audio_type"
    AUDIO_SOCKET=""
    GPU_TYPE="$gpu_type"
    NO_GPU="$no_gpu"
    SMOKE_TEST="$smoke_test"
    KEEP_RUNNING="$keep_running"
    USE_SUDO=""
    SMOKE_STAGING_DIR="/tmp/citrix-smoke-staging.XXXXXX"
    SMOKE_DISTROBOX_DIR="/tmp/citrix-smoke-staging"
    SANDBOX_MODE="none"
    HOME="/tmp/test-home"
    mkdir -p "$HOME/.cache/makepkg"

    case "$display_type" in
        wayland)
            export WAYLAND_DISPLAY="wayland-0"
            export XDG_RUNTIME_DIR="/run/user/1000"
            export DISPLAY=""
            export XAUTHORITY=""
            ;;
        x11)
            export DISPLAY=":0"
            export XAUTHORITY="/tmp/.X11-unix"
            export WAYLAND_DISPLAY=""
            export XDG_RUNTIME_DIR="/run/user/1000"
            ;;
        none)
            export WAYLAND_DISPLAY=""
            export DISPLAY=""
            export XDG_RUNTIME_DIR=""
            export XAUTHORITY=""
            ;;
    esac
    export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/1000/bus"

    : > "$FAKE_CALLS"
}

# --- Validation helpers ---
# tab_to_space <input> -> input with tabs replaced by spaces
tab_to_space() {
    printf '%s' "${1//$'\t'/ }"
}

# Returns 0 if the substring is in any entry of the given array
has_pattern_in() {
    local pattern="$1"; shift
    local entry
    for entry in "$@"; do
        if [[ "$entry" == *"$pattern"* ]]; then
            return 0
        fi
    done
    return 1
}

# Returns 0 if the substring is NOT in any entry of the given array
lacks_pattern_in() {
    local pattern="$1"; shift
    local entry
    for entry in "$@"; do
        if [[ "$entry" == *"$pattern"* ]]; then
            return 1
        fi
    done
    return 0
}

# =====================================================================
# nspawn tests
# =====================================================================

test_nspawn_wayland_pipewire_nvidia() {
    setup wayland pipewire nvidia 0 0 0
    eval "$NSPAWN_BODY_EVAL" 2>/dev/null || true
    run_nspawn_test 2>/dev/null || true

    # fake binary calls (in FAKE_CALLS) for L3 nspawn without smoke-test = empty
    # in-process fake_exec call = the final interactive exec

    local patterns=(
        "--bind-ro=/run/user/1000"
        "WAYLAND_DISPLAY=wayland-0"
        "XDG_RUNTIME_DIR=/run/user/host-1000"
        "--bind=/run/user/1000/pulse"
        "PULSE_SERVER=unix:/run/user/host-1000/pulse/native"
        "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"
        "--bind=/dev/nvidia0"
        "--bind=/dev/nvidiactl"
        "--bind=/dev/nvidia-uvm"
        "LIBGL_ALWAYS_SOFTWARE=0"
        "NVIDIA_DRIVER_CAPABILITIES=all"
        "/bin/bash"
    )
    local all_ok=1
    local pat
    for pat in "${patterns[@]}"; do
        if ! has_pattern_in "$pat" "${EXEC_LOG[@]}"; then
            _fail "[nspawn wayland+pipewire+nvidia] missing pattern: $pat"
            all_ok=0
        fi
    done
    if has_pattern_in "/dev/dri" "${EXEC_LOG[@]}"; then
        _fail "[nspawn wayland+pipewire+nvidia] unexpected /dev/dri"
        all_ok=0
    fi
    if has_pattern_in "--bind=/tmp/.X11-unix" "${EXEC_LOG[@]}"; then
        _fail "[nspawn wayland+pipewire+nvidia] unexpected /tmp/.X11-unix"
        all_ok=0
    fi
    [[ $all_ok -eq 1 ]] && _pass "[nspawn wayland+pipewire+nvidia] all patterns present"
}

test_nspawn_wayland_pipewire_nvidia_no_gpu() {
    setup wayland pipewire nvidia 1 0 0
    eval "$NSPAWN_BODY_EVAL" 2>/dev/null || true
    run_nspawn_test 2>/dev/null || true

    local patterns=(
        "--bind-ro=/run/user/1000"
        "WAYLAND_DISPLAY=wayland-0"
        "--bind=/run/user/1000/pulse"
        "/bin/bash"
    )
    local all_ok=1
    local pat
    for pat in "${patterns[@]}"; do
        if ! has_pattern_in "$pat" "${EXEC_LOG[@]}"; then
            _fail "[nspawn wayland+pipewire+nvidia --no-gpu] missing pattern: $pat"
            all_ok=0
        fi
    done
    if has_pattern_in "/dev/nvidia" "${EXEC_LOG[@]}"; then
        _fail "[nspawn wayland+pipewire+nvidia --no-gpu] unexpected /dev/nvidia"
        all_ok=0
    fi
    if has_pattern_in "NVIDIA_DRIVER_CAPABILITIES" "${EXEC_LOG[@]}"; then
        _fail "[nspawn wayland+pipewire+nvidia --no-gpu] unexpected NVIDIA_DRIVER_CAPABILITIES"
        all_ok=0
    fi
    [[ $all_ok -eq 1 ]] && _pass "[nspawn wayland+pipewire+nvidia --no-gpu] all patterns present"
}

test_nspawn_x11_pulse_intel() {
    setup x11 pulse intel-or-amd 0 0 0
    eval "$NSPAWN_BODY_EVAL" 2>/dev/null || true
    run_nspawn_test 2>/dev/null || true

    local patterns=(
        "--bind=/tmp/.X11-unix"
        "DISPLAY=:0"
        "XAUTHORITY=/tmp/.X11-unix"
        "--bind=/run/user/1000/pulse"
        "PULSE_SERVER=unix:/run/user/host-1000/pulse/native"
        "--bind=/dev/dri"
        "/bin/bash"
    )
    local all_ok=1
    local pat
    for pat in "${patterns[@]}"; do
        if ! has_pattern_in "$pat" "${EXEC_LOG[@]}"; then
            _fail "[nspawn x11+pulse+intel] missing pattern: $pat"
            all_ok=0
        fi
    done
    if has_pattern_in "/dev/nvidia" "${EXEC_LOG[@]}"; then
        _fail "[nspawn x11+pulse+intel] unexpected /dev/nvidia"
        all_ok=0
    fi
    if has_pattern_in "WAYLAND_DISPLAY" "${EXEC_LOG[@]}"; then
        _fail "[nspawn x11+pulse+intel] unexpected WAYLAND_DISPLAY"
        all_ok=0
    fi
    [[ $all_ok -eq 1 ]] && _pass "[nspawn x11+pulse+intel] all patterns present"
}

test_nspawn_x11_noaudio_nogpu() {
    setup x11 none none 0 0 0
    eval "$NSPAWN_BODY_EVAL" 2>/dev/null || true
    run_nspawn_test 2>/dev/null || true

    local patterns=(
        "--bind=/tmp/.X11-unix"
        "DISPLAY=:0"
        "/bin/bash"
    )
    local all_ok=1
    local pat
    for pat in "${patterns[@]}"; do
        if ! has_pattern_in "$pat" "${EXEC_LOG[@]}"; then
            _fail "[nspawn x11+none+none] missing pattern: $pat"
            all_ok=0
        fi
    done
    if has_pattern_in "/dev/dri" "${EXEC_LOG[@]}"; then
        _fail "[nspawn x11+none+none] unexpected /dev/dri"
        all_ok=0
    fi
    if has_pattern_in "PULSE_SERVER" "${EXEC_LOG[@]}"; then
        _fail "[nspawn x11+none+none] unexpected PULSE_SERVER"
        all_ok=0
    fi
    [[ $all_ok -eq 1 ]] && _pass "[nspawn x11+none+none] all patterns present"
}

test_nspawn_smoke_test() {
    setup wayland pipewire nvidia 0 1 0
    eval "$NSPAWN_BODY_EVAL" 2>/dev/null || true
    run_nspawn_test 2>/dev/null || true

    # Read FAKE_CALLS (smoke-test subprocess invocation)
    local fakecalls_lines=()
    if [[ -s "$FAKE_CALLS" ]]; then
        while IFS= read -r line; do
            fakecalls_lines+=("$line")
        done < "$FAKE_CALLS"
    fi

    if [[ ${#fakecalls_lines[@]} -lt 1 ]]; then
        _fail "[nspawn smoke-test] no fake binary calls recorded"
        return
    fi
    if [[ ${#EXEC_LOG[@]} -lt 1 ]]; then
        _fail "[nspawn smoke-test] no in-process exec recorded"
        return
    fi

    local smoke_sp
    smoke_sp="$(tab_to_space "${fakecalls_lines[0]}")"
    if [[ "$smoke_sp" == *"/opt/citrix-smoke/run-smoke.bash"* ]]; then
        _pass "[nspawn smoke-test] smoke invocation has run-smoke.bash"
    else
        _fail "[nspawn smoke-test] smoke invocation missing run-smoke.bash (got: $smoke_sp)"
    fi
    if [[ "$smoke_sp" == *"--bind-ro=$SMOKE_STAGING_DIR:/opt/citrix-smoke"* ]]; then
        _pass "[nspawn smoke-test] smoke invocation has smoke bind mount"
    else
        _fail "[nspawn smoke-test] smoke invocation missing smoke bind mount (got: $smoke_sp)"
    fi

    local last_idx=$(( ${#EXEC_LOG[@]} - 1 ))
    local interactive="${EXEC_LOG[$last_idx]:-}"
    if [[ "$interactive" == *"/bin/bash"* ]]; then
        _pass "[nspawn smoke-test] interactive exec is /bin/bash"
    else
        _fail "[nspawn smoke-test] interactive exec not bash (got: $interactive)"
    fi
    if [[ "$interactive" == *"/opt/citrix-smoke"* ]]; then
        _fail "[nspawn smoke-test] interactive exec has stale smoke mount (got: $interactive)"
    else
        _pass "[nspawn smoke-test] interactive exec has no stale smoke mount"
    fi
}

# =====================================================================
# podman tests
# =====================================================================

test_podman_wayland_pipewire_intel() {
    setup wayland pipewire intel-or-amd 0 0 0
    eval "$PODMAN_BODY_EVAL" 2>/dev/null || true
    run_podman_test 2>/dev/null || true

    local patterns=(
        "-v /run/user/1000:/run/user/1000:Z"
        "WAYLAND_DISPLAY=wayland-0"
        "XDG_RUNTIME_DIR=/run/user/1000"
        "-v /run/user/1000/pulse:/run/user/1000/pulse:Z"
        "PULSE_SERVER=unix:/run/user/1000/pulse/native"
        "--device /dev/dri"
        "archlinux:latest"
        "/bin/bash"
    )
    local all_ok=1
    local pat
    for pat in "${patterns[@]}"; do
        if ! has_pattern_in "$pat" "${EXEC_LOG[@]}"; then
            _fail "[podman wayland+pipewire+intel] missing pattern: $pat"
            all_ok=0
        fi
    done
    if has_pattern_in "/dev/nvidia" "${EXEC_LOG[@]}"; then
        _fail "[podman wayland+pipewire+intel] unexpected /dev/nvidia"
        all_ok=0
    fi
    [[ $all_ok -eq 1 ]] && _pass "[podman wayland+pipewire+intel] all patterns present"
}

test_podman_x11_pulse_nogpu() {
    setup x11 pulse none 0 0 0
    eval "$PODMAN_BODY_EVAL" 2>/dev/null || true
    run_podman_test 2>/dev/null || true

    local patterns=(
        "-v /tmp/.X11-unix:/tmp/.X11-unix:Z"
        "DISPLAY=:0"
        "-v /run/user/1000/pulse:/run/user/1000/pulse:Z"
        "archlinux:latest"
        "/bin/bash"
    )
    local all_ok=1
    local pat
    for pat in "${patterns[@]}"; do
        if ! has_pattern_in "$pat" "${EXEC_LOG[@]}"; then
            _fail "[podman x11+pulse+nogpu] missing pattern: $pat"
            all_ok=0
        fi
    done
    if has_pattern_in "/dev/dri" "${EXEC_LOG[@]}"; then
        _fail "[podman x11+pulse+nogpu] unexpected /dev/dri"
        all_ok=0
    fi
    [[ $all_ok -eq 1 ]] && _pass "[podman x11+pulse+nogpu] all patterns present"
}

test_podman_x11_noaudio_nogpu() {
    setup x11 none none 1 0 0
    eval "$PODMAN_BODY_EVAL" 2>/dev/null || true
    run_podman_test 2>/dev/null || true

    local patterns=(
        "-v /tmp/.X11-unix:/tmp/.X11-unix:Z"
        "DISPLAY=:0"
        "archlinux:latest"
        "/bin/bash"
    )
    local all_ok=1
    local pat
    for pat in "${patterns[@]}"; do
        if ! has_pattern_in "$pat" "${EXEC_LOG[@]}"; then
            _fail "[podman x11+none+none --no-gpu] missing pattern: $pat"
            all_ok=0
        fi
    done
    if has_pattern_in "/dev/dri" "${EXEC_LOG[@]}"; then
        _fail "[podman x11+none+none --no-gpu] unexpected /dev/dri"
        all_ok=0
    fi
    if has_pattern_in "PULSE_SERVER" "${EXEC_LOG[@]}"; then
        _fail "[podman x11+none+none --no-gpu] unexpected PULSE_SERVER"
        all_ok=0
    fi
    [[ $all_ok -eq 1 ]] && _pass "[podman x11+none+none --no-gpu] all patterns present"
}

test_podman_smoke_test() {
    setup wayland pipewire intel-or-amd 0 1 0
    eval "$PODMAN_BODY_EVAL" 2>/dev/null || true
    run_podman_test 2>/dev/null || true

    local fakecalls_lines=()
    if [[ -s "$FAKE_CALLS" ]]; then
        while IFS= read -r line; do
            fakecalls_lines+=("$line")
        done < "$FAKE_CALLS"
    fi

    if [[ ${#fakecalls_lines[@]} -lt 1 ]]; then
        _fail "[podman smoke-test] no fake binary calls recorded"
        return
    fi
    if [[ ${#EXEC_LOG[@]} -lt 1 ]]; then
        _fail "[podman smoke-test] no in-process exec recorded"
        return
    fi

    local smoke_sp
    smoke_sp="$(tab_to_space "${fakecalls_lines[0]}")"
    if [[ "$smoke_sp" == *"-v $SMOKE_STAGING_DIR:/opt/citrix-smoke:ro"* ]]; then
        _pass "[podman smoke-test] smoke invocation has smoke volume mount"
    else
        _fail "[podman smoke-test] smoke invocation missing smoke volume mount (got: $smoke_sp)"
    fi
    if [[ "$smoke_sp" == *"run-smoke.bash"* ]]; then
        _pass "[podman smoke-test] smoke invocation has run-smoke.bash"
    else
        _fail "[podman smoke-test] smoke invocation missing run-smoke.bash"
    fi

    local last_idx=$(( ${#EXEC_LOG[@]} - 1 ))
    local interactive="${EXEC_LOG[$last_idx]:-}"
    if [[ "$interactive" == *"/bin/bash"* ]]; then
        _pass "[podman smoke-test] interactive exec is /bin/bash"
    else
        _fail "[podman smoke-test] interactive exec not bash (got: $interactive)"
    fi
    if [[ "$interactive" == *"/opt/citrix-smoke"* ]]; then
        _fail "[podman smoke-test] interactive exec has stale smoke mount"
    else
        _pass "[podman smoke-test] interactive exec has no stale smoke mount"
    fi
}

# =====================================================================
# distrobox tests
# =====================================================================

test_distrobox_wayland_nvidia() {
    setup wayland pipewire nvidia 0 0 0
    eval "$DISTROBOX_BODY_EVAL" 2>/dev/null || true
    run_distrobox_test 2>/dev/null || true

    local fakecalls_lines=()
    if [[ -s "$FAKE_CALLS" ]]; then
        while IFS= read -r line; do
            fakecalls_lines+=("$line")
        done < "$FAKE_CALLS"
    fi

    local found_create_with_nvidia=0
    local line line_sp
    for line in "${fakecalls_lines[@]}"; do
        line_sp="$(tab_to_space "$line")"
        if [[ "$line_sp" == *"distrobox create"* ]] && [[ "$line_sp" == *"--nvidia"* ]]; then
            found_create_with_nvidia=1
            break
        fi
    done
    if [[ $found_create_with_nvidia -eq 1 ]]; then
        _pass "[distrobox wayland+nvidia] create has --nvidia"
    else
        _fail "[distrobox wayland+nvidia] no 'distrobox create ... --nvidia' in fake calls"
    fi

    local found_enter=0
    for line in "${EXEC_LOG[@]}"; do
        line_sp="$(tab_to_space "$line")"
        if [[ "$line_sp" == *"distrobox enter citrix-test"* ]]; then
            found_enter=1
            break
        fi
    done
    if [[ $found_enter -eq 1 ]]; then
        _pass "[distrobox wayland+nvidia] enter invocation present"
    else
        _fail "[distrobox wayland+nvidia] no 'distrobox enter citrix-test' in EXEC_LOG"
    fi
}

test_distrobox_wayland_intel() {
    setup wayland pipewire intel-or-amd 0 0 0
    eval "$DISTROBOX_BODY_EVAL" 2>/dev/null || true
    run_distrobox_test 2>/dev/null || true

    local fakecalls_lines=()
    if [[ -s "$FAKE_CALLS" ]]; then
        while IFS= read -r line; do
            fakecalls_lines+=("$line")
        done < "$FAKE_CALLS"
    fi

    local line line_sp
    for line in "${fakecalls_lines[@]}"; do
        line_sp="$(tab_to_space "$line")"
        if [[ "$line_sp" == *"distrobox create"* ]] && [[ "$line_sp" == *"--nvidia"* ]]; then
            _fail "[distrobox wayland+intel] unexpected --nvidia on intel host (line: $line_sp)"
        fi
    done
    _pass "[distrobox wayland+intel] no --nvidia on intel host"
}

test_distrobox_smoke_test() {
    setup wayland pipewire nvidia 0 1 0
    eval "$DISTROBOX_BODY_EVAL" 2>/dev/null || true
    run_distrobox_test 2>/dev/null || true

    local fakecalls_lines=()
    if [[ -s "$FAKE_CALLS" ]]; then
        while IFS= read -r line; do
            fakecalls_lines+=("$line")
        done < "$FAKE_CALLS"
    fi

    if [[ ${#fakecalls_lines[@]} -lt 1 ]]; then
        _fail "[distrobox smoke-test] no fake binary calls recorded"
        return
    fi
    if [[ ${#EXEC_LOG[@]} -lt 1 ]]; then
        _fail "[distrobox smoke-test] no in-process exec recorded"
        return
    fi

    local found_smoke=0
    local line
    for line in "${fakecalls_lines[@]}"; do
        if [[ "$line" == *"run-smoke.bash"* ]]; then
            found_smoke=1
            break
        fi
    done
    if [[ $found_smoke -eq 1 ]]; then
        _pass "[distrobox smoke-test] found smoke-test invocation in FAKE_CALLS"
    else
        _fail "[distrobox smoke-test] no smoke-test invocation in FAKE_CALLS"
    fi

    local last_idx=$(( ${#EXEC_LOG[@]} - 1 ))
    local interactive="${EXEC_LOG[$last_idx]:-}"
    if [[ "$interactive" == *"distrobox enter citrix-test"* ]]; then
        _pass "[distrobox smoke-test] interactive exec is 'distrobox enter citrix-test'"
    else
        _fail "[distrobox smoke-test] interactive exec wrong (got: $interactive)"
    fi
}

# =====================================================================
# Run all tests
# =====================================================================

echo "=== L3 launcher argument-assembly tests ==="
echo

test_nspawn_wayland_pipewire_nvidia
test_nspawn_wayland_pipewire_nvidia_no_gpu
test_nspawn_x11_pulse_intel
test_nspawn_x11_noaudio_nogpu
test_nspawn_smoke_test

test_podman_wayland_pipewire_intel
test_podman_x11_pulse_nogpu
test_podman_x11_noaudio_nogpu
test_podman_smoke_test

test_distrobox_wayland_nvidia
test_distrobox_wayland_intel
test_distrobox_smoke_test

echo
echo "=== Summary: $PASS_COUNT passed, $FAIL_COUNT failed ==="
if [[ $FAIL_COUNT -gt 0 ]]; then
    echo "Failed tests:"
    for t in "${FAILED_TESTS[@]}"; do
        echo "  - $t"
    done
    exit 1
fi
exit 0
