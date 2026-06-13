#!/usr/bin/env bash
# test-variant-matrix.bash - Comprehensive test matrix for test-variant.bash.
#
# Runs the same test cases documented in CHANGELOG.md (the 24-case matrix
# that has been used to validate each iteration of the orchestrator) plus
# the L3 launcher argument-assembly tests from test-l3-args.bash.
#
# Usage: scripts/test-variant-matrix.bash [quick|full]
#   quick (default): skip the L2 build and L3 launch tests, run only the
#                    fast argument-parsing + L0 + L3 launcher tests
#   full:            run everything, including L2 build of the minimal test
#                    variant (~10s) and the L2 build failure case
#
# Exit code: 0 if all pass, 1 if any fail.
#
# The script depends on test fixtures in pkgbuilds/ (created on first run):
#   - pkgbuilds/_w-warnings-only/   (PKGBUILD with no namcap errors)
#   - pkgbuilds/_e-empty-desc/      (PKGBUILD with namcap E: error)
#   - pkgbuilds/_minimal-build/     (PKGBUILD that builds in ~10s)
#   - pkgbuilds/_fail-build/        (PKGBUILD whose build() always fails)
#   - pkgbuilds/group/test-pkg/     (PKGBUILD with a slash in the variant
#                                    name, for path sanitization testing)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_VARIANT="${REPO_DIR}/scripts/test-variant.bash"
TEST_L3="${REPO_DIR}/scripts/test-l3-args.bash"
MODE="${1:-quick}"

# --- Result tracking ---
PASS_COUNT=0
FAIL_COUNT=0
FAILED_TESTS=()

_pass() { printf '  [PASS] %s\n' "$*"; PASS_COUNT=$((PASS_COUNT+1)); }
_fail() { printf '  [FAIL] %s\n' "$*"; FAIL_COUNT=$((FAIL_COUNT+1)); FAILED_TESTS+=("$*"); }
_section() { printf '\n--- %s ---\n' "$*"; }

# --- Run the variant script and capture its output + exit code ---
LAST_OUT=""
LAST_RC=0

run_variant() {
    local args=("$@")
    LAST_OUT="$("${TEST_VARIANT}" "${args[@]}" 2>&1)"
    LAST_RC=$?
}

# Run a specific script path (for symlink tests)
run_variant_path() {
    local script="$1"
    shift
    LAST_OUT="$("$script" "$@" 2>&1)"
    LAST_RC=$?
}

# --- Assertion helpers ---
expect_exit() {
    local label="$1"
    local expected="$2"
    shift 2
    run_variant "$@"
    if [[ $LAST_RC -eq $expected ]]; then
        _pass "$label (exit=$LAST_RC)"
    else
        _fail "$label (expected=$expected, got $LAST_RC)"
    fi
}

# --- Ensure test fixtures exist (created in pkgbuilds/, underscore-prefixed
# so they are excluded from git). ---
ensure_test_variants() {
    # _w-warnings-only: clean PKGBUILD that builds quickly
    if [[ ! -f "${REPO_DIR}/pkgbuilds/_w-warnings-only/PKGBUILD" ]]; then
        mkdir -p "${REPO_DIR}/pkgbuilds/_w-warnings-only"
        cat > "${REPO_DIR}/pkgbuilds/_w-warnings-only/PKGBUILD" <<'EOF'
# Maintainer: Test <test@example.com>
pkgname=citrix-test-warnings
pkgver=1.0
pkgrel=1
pkgdesc="Test variant with warnings only"
arch=('x86_64')
url='https://example.com'
license=('MIT')
depends=('glibc')

package() {
    mkdir -p "${pkgdir}/opt/test"
    echo "test" > "${pkgdir}/opt/test/marker"
}
EOF
    fi
    
    # _e-empty-desc: PKGBUILD with namcap E: error
    if [[ ! -f "${REPO_DIR}/pkgbuilds/_e-empty-desc/PKGBUILD" ]]; then
        mkdir -p "${REPO_DIR}/pkgbuilds/_e-empty-desc"
        cat > "${REPO_DIR}/pkgbuilds/_e-empty-desc/PKGBUILD" <<'EOF'
# Maintainer: Test <test@example.com>
pkgname=citrix-test-error
pkgver=1.0
pkgrel=1
pkgdesc=""
arch=('x86_64')
url='https://example.com'
license=('MIT')
source=("https://example.com/${pkgname}-${pkgver}.tar.gz")
sha256sums=('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')

package() {
    mkdir -p "${pkgdir}/opt/test"
}
EOF
    fi
    
    # _no-pkgbuild: empty directory
    if [[ ! -d "${REPO_DIR}/pkgbuilds/_no-pkgbuild" ]]; then
        mkdir -p "${REPO_DIR}/pkgbuilds/_no-pkgbuild"
    fi
    
    if [[ "$MODE" == "full" ]]; then
        # _minimal-build: builds in ~10s
        if [[ ! -f "${REPO_DIR}/pkgbuilds/_minimal-build/PKGBUILD" ]]; then
            mkdir -p "${REPO_DIR}/pkgbuilds/_minimal-build"
            cat > "${REPO_DIR}/pkgbuilds/_minimal-build/PKGBUILD" <<'EOF'
# Maintainer: Test <test@example.com>
pkgname=citrix-minimal-test
pkgver=1.0
pkgrel=1
pkgdesc="Minimal test build for the orchestrator"
arch=('x86_64')
url='https://example.com'
license=('MIT')
depends=('glibc')

package() {
    mkdir -p "${pkgdir}/opt/test"
    echo "test build" > "${pkgdir}/opt/test/marker"
}
EOF
        fi
        
        # _fail-build: build() always fails
        if [[ ! -f "${REPO_DIR}/pkgbuilds/_fail-build/PKGBUILD" ]]; then
            mkdir -p "${REPO_DIR}/pkgbuilds/_fail-build"
            cat > "${REPO_DIR}/pkgbuilds/_fail-build/PKGBUILD" <<'EOF'
# Maintainer: Test <test@example.com>
pkgname=citrix-fail-test
pkgver=1.0
pkgrel=1
pkgdesc="Test (build is supposed to fail)"
arch=('x86_64')
url='https://example.com'
license=('MIT')
depends=('glibc')

build() {
    echo "This build is supposed to fail" >&2
    exit 1
}

package() {
    mkdir -p "${pkgdir}/opt/test"
}
EOF
        fi
    fi
    
    # _group/test-pkg: slash in variant name (path sanitization). The
    # underscore prefix is required so the existing /pkgbuilds/_*/ pattern
    # in .gitignore covers it.
    if [[ ! -f "${REPO_DIR}/pkgbuilds/_group/test-pkg/PKGBUILD" ]]; then
        mkdir -p "${REPO_DIR}/pkgbuilds/_group/test-pkg"
        cat > "${REPO_DIR}/pkgbuilds/_group/test-pkg/PKGBUILD" <<'EOF'
# Maintainer: Test <test@example.com>
pkgname=citrix-group-test
pkgver=1.0
pkgrel=1
pkgdesc="Test variant in a sub-group directory"
arch=('x86_64')
url='https://example.com'
license=('MIT')
depends=('glibc')

package() {
    mkdir -p "${pkgdir}/opt/group-test"
    echo "group test" > "${pkgdir}/opt/group-test/marker"
}
EOF
    fi
}

# Create the test fixture variants now (idempotent; the function above
# only writes files that don't already exist).
ensure_test_variants

# =====================================================================
# Argument parsing
# =====================================================================
_section "Argument parsing"

expect_exit "--help"              0 --help
expect_exit "-h"                  0 -h
expect_exit "no args"             1
expect_exit "unknown option"      1 --bogus
expect_exit "--sandbox (no val)"  1 --sandbox
expect_exit "--sandbox= (empty)"  1 --sandbox=
expect_exit "--sandbox=invalid"   1 --sandbox=invalid
expect_exit "--chroot-dir (no val)" 1 --chroot-dir
expect_exit "--chroot-dir= (empty)" 1 --chroot-dir=
expect_exit "two positional args" 1 latest extra
expect_exit "nonexistent variant" 1 nonexistent
expect_exit "missing PKGBUILD"    1 _no-pkgbuild
expect_exit "variant with E:"     1 _e-empty-desc
expect_exit "L0 on latest"        0 latest --no-build
expect_exit "L0 on clean variant" 0 _w-warnings-only --no-build

# =====================================================================
# Flag combinations
# =====================================================================
_section "Flag combinations"

expect_exit "--smoke-test --sandbox=none fails early" 1 latest --smoke-test
expect_exit "--keep-running without --smoke-test fails" 1 latest --keep-running
expect_exit "--no-build + --smoke-test (default sandbox) dies" 1 latest --no-build --smoke-test
expect_exit "--no-build + --smoke-test (valid sandbox) warns" 0 latest --no-build --smoke-test --sandbox=distrobox
expect_exit "--no-build + --keep-running dies" 1 latest --no-build --keep-running
expect_exit "--smoke-test + --keep-running + sandbox=none fails" 1 latest --smoke-test --keep-running

# Verify the --no-build + --smoke-test warn is actually emitted
run_variant latest --no-build --smoke-test --sandbox=distrobox
if [[ "$LAST_OUT" == *"--smoke-test has no effect with --no-build"* ]]; then
    _pass "[--no-build + --smoke-test warns correctly]"
else
    _fail "[--no-build + --smoke-test warn missing]"
fi

# =====================================================================
# L2 with clean variant (path sanitization) — full mode only
# =====================================================================
if [[ "$MODE" == "full" ]]; then
    _section "L2 with clean variant (path sanitization)"
    
    expect_exit "L2 with kebab-case variant" 0 _minimal-build
    expect_exit "L2 with slash variant" 0 _group/test-pkg
fi

# =====================================================================
# REPO_ROOT fix (run from outside repo)
# =====================================================================
_section "REPO_ROOT fix (run from outside repo)"

( cd /tmp && run_variant_path "${TEST_VARIANT}" latest --no-build )
if [[ $LAST_RC -eq 0 ]]; then
    _pass "REPO_ROOT from /tmp (exit=0)"
else
    _fail "REPO_ROOT from /tmp (got exit=$LAST_RC)"
fi

# =====================================================================
# Symlink resolution
# =====================================================================
_section "Symlink resolution"

ln -sf "${TEST_VARIANT}" /tmp/tv-symlink-test 2>/dev/null
( cd /tmp && run_variant_path /tmp/tv-symlink-test latest --no-build )
if [[ $LAST_RC -eq 0 ]]; then
    _pass "symlink to script (exit=0)"
else
    _fail "symlink to script (got exit=$LAST_RC)"
fi
rm -f /tmp/tv-symlink-test

# =====================================================================
# L2 build failure — full mode only
# =====================================================================
if [[ "$MODE" == "full" ]]; then
    _section "L2 build failure"
    expect_exit "L2 build failure exit=2" 2 _fail-build
fi

# =====================================================================
# L3 launcher argument-assembly tests
# =====================================================================
_section "L3 launcher argument-assembly tests"

# Run the L3 test script; its exit code is 0/1
if bash "${TEST_L3}" 2>&1 | tail -25; then
    _pass "L3 launcher argument-assembly tests"
else
    _fail "L3 launcher argument-assembly tests"
fi

# =====================================================================
# Summary
# =====================================================================
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
