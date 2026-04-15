#!/bin/bash
# benchmark-dtls-bwrap.sh -- run benchmark-dtls.sh inside a bubblewrap
# sandbox that only permits writes under the current working directory.
#
# Usage (from anywhere; iperf tree is auto-detected from the script's
# location):
#     ./scripts/benchmark-dtls-bwrap.sh
#     DUR=5 PARALLELS="1 4" ./scripts/benchmark-dtls-bwrap.sh
#
# The benchmark tree is created at ./dtls-bench by default (override
# with BENCH_DIR).  Anything the underlying script tries to write
# outside of (a) the iperf repository itself and (b) BENCH_DIR will
# fail with EROFS, which is the point.
#
# Requires: bubblewrap (apt-get install bubblewrap, or dnf install
# bubblewrap), plus all the build tools the underlying script needs.

set -euo pipefail

command -v bwrap >/dev/null 2>&1 \
    || { echo "bwrap not installed; apt install bubblewrap" >&2; exit 1; }

# The iperf repo is two levels up from this script (scripts/<here>).
IPERF_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "${IPERF_ROOT}/configure.ac" ] \
    || { echo "not the iperf repo root: ${IPERF_ROOT}" >&2; exit 1; }

# All persistent output goes under BENCH_DIR.  Default it to a
# subdirectory of $PWD so a clean invocation leaves no trace outside
# the caller's current directory.
BENCH_DIR="${BENCH_DIR:-$PWD/dtls-bench}"
mkdir -p "${BENCH_DIR}"
BENCH_DIR="$(cd "${BENCH_DIR}" && pwd)"   # absolute path, for bwrap

# Both paths must be writable inside the sandbox: the iperf tree
# (autotools regenerates Makefile.in etc. during the per-variant
# configure) and the bench tree (for cloned sources, installs,
# binaries, JSON).  Everything else is read-only.
#
# /tmp is given its own in-sandbox tmpfs so anything the build pipeline
# puts there (temp files, ld caches, etc.) doesn't escape.
exec bwrap \
    --ro-bind /usr    /usr    \
    --ro-bind /bin    /bin    \
    --ro-bind /lib    /lib    \
    --ro-bind /lib64  /lib64  \
    --ro-bind /sbin   /sbin   \
    --ro-bind /etc    /etc    \
    --dev /dev                \
    --proc /proc              \
    --tmpfs /tmp              \
    --bind "${IPERF_ROOT}" "${IPERF_ROOT}" \
    --bind "${BENCH_DIR}"  "${BENCH_DIR}"  \
    --chdir "${PWD}"         \
    --share-net              \
    --unshare-pid            \
    --unshare-uts            \
    --unshare-ipc            \
    --die-with-parent        \
    --setenv BENCH_DIR "${BENCH_DIR}" \
    "${IPERF_ROOT}/scripts/benchmark-dtls.sh" "$@"
