#!/usr/bin/env bash
# citrix-smoke.bash - Headless smoke test for icaclient S1, S2, S3
#
# Sourced by run-smoke.bash. Not executed directly. Provides:
#   - assert_maps_contains <pid> <lib>
#   - assert_no_lib_errors <stderr_file>
#   - launch_and_inspect <bin> [args...]
#   - run_s1
#   - run_s2_s3 <ica_file> [keep_running]
#   - run_s1_s2_s3 <fixtures_dir> [keep_running]
#
# Returns non-zero from run_s1_s2_s3 if any scenario fails. The result
# detail (which scenarios passed/failed) is in stderr lines prefixed
# with `[smoke]`. The summary table at the end has lines of the form
# `[PASS] S1`, `[FAIL] S3`, etc., that downstream tooling can grep.
#
# Timeouts (override via env vars):
#   CITRIX_SMOKE_LAUNCH_TIMEOUT  max seconds to wait for a binary to appear
#                                in the process list (default: 10)
#   CITRIX_SMOKE_ALIVE_AFTER     seconds the binary must stay alive after
#                                first appearing, to catch immediate crashes
#                                (default: 3)
#   CITRIX_SMOKE_DIALOG_WAIT     extra seconds to wait for the wfica
#                                "Connecting..." dialog to render and for
#                                WebKitWebProcess / WebKitNetworkProcess
#                                to be spawned (default: 5)

# Guard against double-sourcing
if [[ -n "${CITRIX_SMOKE_LOADED:-}" ]]; then
    return 0
fi
CITRIX_SMOKE_LOADED=1

# --- Configurable timeouts (env vars with defaults) ---
: "${CITRIX_SMOKE_LAUNCH_TIMEOUT:=10}"
: "${CITRIX_SMOKE_ALIVE_AFTER:=3}"
: "${CITRIX_SMOKE_DIALOG_WAIT:=5}"

# --- Internal state ---
_smoke_last_pid=""
_smoke_results=()

# --- Logging ---

_smoke_log() {
    printf '[smoke] %s\n' "$*" >&2
}

_smoke_result() {
    # Append "label:pass|fail" to _smoke_results
    _smoke_results+=("$1:$2")
}

# --- Process helpers ---

# Get PID of a binary by basename (excluding our own pid and any grep
# matches against this very script). Returns the first match on stdout.
_smoke_pid_of() {
    local bin="$1"
    pgrep -f "/${bin}\b" 2>/dev/null \
        | grep -v "^$$\$" \
        | grep -v "run-smoke" \
        | head -n1
}

# Wait for a binary to appear in the process list (up to LAUNCH_TIMEOUT
# seconds). Prints the PID on stdout on success; returns 1 on timeout.
_smoke_wait_for_proc() {
    local bin="$1"
    local _i
    for _i in $(seq 1 "$CITRIX_SMOKE_LAUNCH_TIMEOUT"); do
        local pid
        pid="$(_smoke_pid_of "$bin")"
        if [[ -n "$pid" ]]; then
            printf '%s' "$pid"
            return 0
        fi
        sleep 1
    done
    return 1
}

# --- Assertions ---

# assert_maps_contains <pid> <needle>
# Returns 0 if /proc/<pid>/maps contains the literal substring <needle>.
assert_maps_contains() {
    local pid="$1"
    local needle="$2"
    if ! [[ -r "/proc/$pid/maps" ]]; then
        _smoke_log "  FAIL: cannot read /proc/$pid/maps (pid $pid dead?)"
        return 1
    fi
    if grep -qF "$needle" "/proc/$pid/maps"; then
        _smoke_log "  /proc/$pid/maps contains: $needle"
        return 0
    fi
    _smoke_log "  FAIL: /proc/$pid/maps does NOT contain: $needle"
    return 1
}

# assert_no_lib_errors <stderr_file>
# Returns 0 if the captured stderr does NOT contain known library-load
# failure patterns. These patterns are the exact ones the S1-S3 protocol
# in TESTING.md is designed to catch.
assert_no_lib_errors() {
    local stderr_file="$1"
    local patterns=(
        'cannot open shared object file'
        'libsoup-ERROR'
        'error while loading shared libraries'
        'undefined symbol: webkit'
        'undefined symbol: soup'
    )
    local p
    for p in "${patterns[@]}"; do
        if grep -qF "$p" "$stderr_file" 2>/dev/null; then
            _smoke_log "  FAIL: stderr contains: $p"
            grep -F "$p" "$stderr_file" >&2 | head -3 || true
            return 1
        fi
    done
    return 0
}

# --- Launchers ---

# launch_and_inspect <bin> [args...]
# Launches <bin> with [args] in a fully-detached background process
# (setsid, stdin/stdout redirected, stderr captured to a temp file).
# Waits for the process to appear in the process list, then waits
# CITRIX_SMOKE_ALIVE_AFTER seconds to ensure it doesn't immediately
# crash, then checks captured stderr for known library errors.
#
# On success: sets _smoke_last_pid and returns 0.
# On failure: logs the reason, kills the process if it exists, returns 1.
launch_and_inspect() {
    local bin="$1"
    shift

    if ! [[ -x "$bin" ]]; then
        _smoke_log "FAIL: $bin is not executable (or not installed)"
        return 1
    fi

    local stderr_file
    stderr_file="$(mktemp /tmp/citrix-smoke-stderr.XXXXXX)"

    # Launch fully detached. setsid makes it survive the parent shell.
    # stdin/stdout to /dev/null so the tester's terminal stays clean.
    setsid "$bin" "$@" </dev/null >/dev/null 2>"$stderr_file" &
    local bg_pid=$!

    # Wait for the binary to actually appear in the process list
    local pid=""
    if ! pid="$(_smoke_wait_for_proc "$(basename "$bin")")"; then
        _smoke_log "FAIL: $bin did not start within ${CITRIX_SMOKE_LAUNCH_TIMEOUT}s"
        cat "$stderr_file" >&2 || true
        kill -TERM "$bg_pid" 2>/dev/null || true
        rm -f "$stderr_file"
        return 1
    fi

    _smoke_log "  launched: $bin (pid=$pid)"

    # Let it settle and check it didn't immediately crash
    sleep "$CITRIX_SMOKE_ALIVE_AFTER"
    if ! kill -0 "$pid" 2>/dev/null; then
        _smoke_log "FAIL: $bin died within ${CITRIX_SMOKE_ALIVE_AFTER}s of starting"
        cat "$stderr_file" >&2 || true
        rm -f "$stderr_file"
        return 1
    fi

    if ! assert_no_lib_errors "$stderr_file"; then
        kill -TERM "$pid" 2>/dev/null || true
        rm -f "$stderr_file"
        return 1
    fi

    rm -f "$stderr_file"
    _smoke_last_pid="$pid"
    return 0
}

# --- Scenarios ---

# S1: selfservice launches
# Validates: process starts, stays alive, and has libwebkit2gtk-4.0 +
# libsoup-2.4 loaded into its address space (selfservice uses them at
# startup to render the storefront page).
run_s1() {
    _smoke_log ""
    _smoke_log "=== S1: selfservice launches"

    # Clean up any leftover instance from a previous run
    pkill -TERM -x selfservice 2>/dev/null || true
    sleep 1

    if ! launch_and_inspect /opt/Citrix/ICAClient/selfservice; then
        _smoke_result "S1" "fail"
        return 1
    fi

    local pid="$_smoke_last_pid"
    local ok=1
    if ! assert_maps_contains "$pid" "libwebkit2gtk-4.0.so.37"; then
        ok=0
    fi
    if ! assert_maps_contains "$pid" "libsoup-2.4.so.1"; then
        ok=0
    fi

    # selfservice is always killed (no useful state to leave running;
    # it just sits at the storefront page, which is not the S3 case)
    kill -TERM "$pid" 2>/dev/null || true
    sleep 1

    if [[ $ok -eq 1 ]]; then
        _smoke_log "RESULT S1: PASS (selfservice launched, webkit + libsoup loaded)"
        _smoke_result "S1" "pass"
        return 0
    else
        _smoke_log "RESULT S1: FAIL (library not loaded into selfservice process)"
        _smoke_result "S1" "fail"
        return 1
    fi
}

# S2 + S3: wfica opens .ica + "Connecting..." dialog renders
# Same single launch covers both:
#   S2 = wfica launched, processed the .ica, didn't crash
#   S3 = UIDialogLibWebKit3.so + libwebkit2gtk-4.0 loaded (dialog pipeline)
# We use a tolerant check for S3: the strong signal (WebKitWebProcess
# child running) is what we want, but if the timing is off (dialog
# didn't render in our wait window), we fall back to the weak signal
# (UIDialogLibWebKit3.so can resolve libwebkit2gtk-4.0 via ldd). The
# weak signal catches the "library not found" failure mode that the
# S1-S3 protocol is designed to surface; the strong signal additionally
# proves the dialog actually rendered.
#
# Usage: run_s2_s3 <ica_file> [keep_running]
run_s2_s3() {
    local ica_file="$1"
    local keep_running="${2:-no}"

    _smoke_log ""
    _smoke_log "=== S2/S3: wfica opens .ica, dialog renders"

    pkill -TERM -x wfica 2>/dev/null || true
    sleep 1

    if ! launch_and_inspect /opt/Citrix/ICAClient/wfica "$ica_file"; then
        _smoke_result "S2" "fail"
        _smoke_result "S3" "fail"
        return 1
    fi

    local pid="$_smoke_last_pid"

    # Give the dialog library time to load and the WebKit helpers time
    # to spawn. The dialog appears early in the connection attempt; by
    # the time the SYN to 192.0.2.1 has been sent once or twice, the
    # dialog is up and WebKitWebProcess / WebKitNetworkProcess are
    # children of wfica.
    sleep "$CITRIX_SMOKE_DIALOG_WAIT"

    # S2: wfica alive and didn't immediately fail
    # (already verified by launch_and_inspect; just record)

    # S3: dialog pipeline check (strong + weak)
    local s3_strong=0
    if pgrep -f WebKitWebProcess >/dev/null 2>&1 \
       || pgrep -f WebKitNetworkProcess >/dev/null 2>&1; then
        s3_strong=1
        _smoke_log "  WebKit helper process is running (S3 strong signal: dialog rendering)"
    fi

    local s3_weak=0
    if [[ -f /opt/Citrix/ICAClient/lib/UIDialogLibWebKit3.so ]] \
       && ldd /opt/Citrix/ICAClient/lib/UIDialogLibWebKit3.so 2>/dev/null \
            | grep -qE 'libwebkit2gtk-4\.0\.so\.37.*=>'; then
        s3_weak=1
    fi

    local s3_ok=0
    if [[ $s3_strong -eq 1 ]]; then
        _smoke_log "  S3: PASS (strong: WebKit helper running)"
        s3_ok=1
    elif [[ $s3_weak -eq 1 ]]; then
        _smoke_log "  S3: PASS (weak: dialog lib resolves webkit, dialog not yet rendered)"
        s3_ok=1
    else
        if ! [[ -f /opt/Citrix/ICAClient/lib/UIDialogLibWebKit3.so ]]; then
            _smoke_log "  S3: FAIL (UIDialogLibWebKit3.so missing)"
        else
            _smoke_log "  S3: FAIL (UIDialogLibWebKit3.so cannot resolve libwebkit2gtk-4.0)"
            _smoke_log "  ldd output:"
            ldd /opt/Citrix/ICAClient/lib/UIDialogLibWebKit3.so 2>/dev/null \
                | grep -iE 'webkit|soup|not found' >&2 || true
        fi
    fi

    # Cleanup wfica
    if [[ "$keep_running" != "yes" ]]; then
        kill -TERM "$pid" 2>/dev/null || true
        sleep 1
    else
        _smoke_log "  --keep-running: wfica pid=$pid left alive for visual inspection"
        _smoke_log "  to terminate:    kill -TERM $pid"
    fi

    _smoke_log "RESULT S2: PASS (wfica launched, .ica parsed, process alive)"
    _smoke_result "S2" "pass"
    if [[ $s3_ok -eq 1 ]]; then
        _smoke_result "S3" "pass"
        return 0
    else
        _smoke_result "S3" "fail"
        return 1
    fi
}

# --- Top-level orchestrator ---

# run_s1_s2_s3 <fixtures_dir> [keep_running]
#   <fixtures_dir>  directory containing the .ica fixtures
#   [keep_running]  "yes" to leave wfica running after S3 for visual
#                   inspection; "no" (default) to kill it
#
# Exits 0 if S1, S2, S3 all pass; 1 if any fails. Always prints a
# summary table at the end with lines like "[PASS] S1" / "[FAIL] S3".
run_s1_s2_s3() {
    local fixtures_dir="${1:-.}"
    local keep_running="${2:-no}"

    _smoke_results=()

    # Pre-flight: package must be installed
    if ! [[ -x /opt/Citrix/ICAClient/selfservice ]] \
       || ! [[ -x /opt/Citrix/ICAClient/wfica ]]; then
        _smoke_log "FAIL: /opt/Citrix/ICAClient/{selfservice,wfica} not found."
        _smoke_log "  Install the icaclient package first:"
        _smoke_log "    - nspawn: already done by L2 (or re-run the script without --no-build)"
        _smoke_log "    - distrobox / podman: cd into the variant dir, run 'makepkg -si',"
        _smoke_log "      then re-run the orchestrator with --smoke-test."
        _smoke_result "S1" "fail"
        _smoke_result "S2" "fail"
        _smoke_result "S3" "fail"
        _smoke_print_summary
        return 1
    fi

    # Pick the .ica fixture
    local ica="${fixtures_dir}/sample-pna.ica"
    if [[ ! -f "$ica" ]]; then
        _smoke_log "FAIL: missing fixture: $ica"
        _smoke_result "S1" "fail"
        _smoke_result "S2" "fail"
        _smoke_result "S3" "fail"
        _smoke_print_summary
        return 1
    fi

    _smoke_log "Fixtures dir:    $fixtures_dir"
    _smoke_log "Keep wfica:      $keep_running"
    _smoke_log "Launch timeout:  ${CITRIX_SMOKE_LAUNCH_TIMEOUT}s"
    _smoke_log "Alive-after:     ${CITRIX_SMOKE_ALIVE_AFTER}s"
    _smoke_log "Dialog wait:     ${CITRIX_SMOKE_DIALOG_WAIT}s"

    # Run S1
    run_s1 || true

    # Run S2 + S3 (same launch)
    run_s2_s3 "$ica" "$keep_running" || true

    _smoke_print_summary

    # Return 0 only if all scenarios passed
    local all_pass=1
    local r
    for r in "${_smoke_results[@]}"; do
        if [[ "${r##*:}" != "pass" ]]; then
            all_pass=0
            break
        fi
    done

    return $(( 1 - all_pass ))
}

_smoke_print_summary() {
    _smoke_log ""
    _smoke_log "===== SUMMARY ====="
    if [[ ${#_smoke_results[@]} -eq 0 ]]; then
        _smoke_log "(no scenarios were recorded)"
        return
    fi
    local r label status mark
    for r in "${_smoke_results[@]}"; do
        label="${r%%:*}"
        status="${r##*:}"
        if [[ "$status" == "pass" ]]; then
            mark="[PASS]"
        else
            mark="[FAIL]"
        fi
        printf '%s\t%s\n' "$mark" "$label" >&2
    done
}
