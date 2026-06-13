#!/usr/bin/env bash
# run-smoke.bash - Driver for the icaclient S1-S3 smoke test
#
# This script is staged by `scripts/test-variant.bash --smoke-test` at
# /opt/citrix-smoke/ inside the L3 sandbox (distrobox / systemd-nspawn /
# podman). It sources citrix-smoke.bash from the same directory and runs
# the S1, S2, S3 scenarios against the staged .ica fixtures.
#
# Usage: run-smoke.bash [keep_running]
#   keep_running=yes  leaves wfica alive after S3 (for visual inspection)
#   keep_running=no   (default) kills wfica at the end of S2/S3

# Note: -e is intentionally NOT set. The smoke library tracks its own
# per-scenario pass/fail and returns 0/1 from run_s1_s2_s3. We want each
# scenario to attempt all of its checks even if an earlier one failed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# citrix-smoke.bash is staged alongside this script by the orchestrator
# shellcheck source=scripts/lib/citrix-smoke.bash
source "${SCRIPT_DIR}/citrix-smoke.bash"

keep_running="${1:-no}"
run_s1_s2_s3 "$SCRIPT_DIR" "$keep_running"
