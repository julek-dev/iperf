#!/bin/bash
# benchmark-dtls.sh -- self-contained reproducer for iperf's DTLS 1.2
# loopback benchmark.
#
# What it does:
#   1. Clones wolfSSL from upstream (github.com/wolfSSL/wolfssl) into
#      $BENCH_DIR/src and builds it with the Intel-optimized flag set
#      that produces parity with OpenSSL.
#   2. Downloads and builds OpenSSL 1.1.1w from upstream.
#   3. Leaves the distro OpenSSL 3 alone and uses it as-is.
#   4. Builds three iperf3 variants from the current source tree (one
#      per SSL backend) -- each with its own libiperf.so shim under
#      $BENCH_DIR/bin/ so the variants don't collide at runtime.
#   5. Runs two benchmark sweeps on loopback:
#        - Single-core pinned (pin_cli / pin_srv) for UDP + the three
#          DTLS stacks.
#        - Multi-thread (-P 1/2/4/8) for the same four stacks.
#   6. Prints a formatted summary and keeps every run's iperf3 JSON
#      under $RESULTS_DIR/.
#
# Everything lives under a single $BENCH_DIR (default: a new mktemp
# directory so repeated runs don't collide).  The script is idempotent:
# each step is skipped if its output already exists.  Re-run with
# BENCH_DIR pointed at the previous tree to avoid rebuilding anything.
#
# Usage:
#     ./scripts/benchmark-dtls.sh                       # full sweep
#     DUR=10 PARALLELS="1 4" ./scripts/benchmark-dtls.sh
#     SKIP_PINNED=1   ./scripts/benchmark-dtls.sh       # only the -P sweep
#     SKIP_PARALLEL=1 ./scripts/benchmark-dtls.sh       # only the pinned sweep
#     BENCH_DIR=$HOME/dtls-bench ./scripts/benchmark-dtls.sh   # persistent

set -euo pipefail

# ---------------------------------------------------------------- config
DUR="${DUR:-30}"
BLKSZ="${BLKSZ:-1200}"
PARALLELS="${PARALLELS:-1 2 4 8}"

# Default BENCH_DIR to a fresh temp dir so repeated invocations don't
# collide; override for persistent/incremental runs.
BENCH_DIR="${BENCH_DIR:-$(mktemp -d -t iperf-dtls-bench.XXXXXX)}"

IPERF_SRC="${IPERF_SRC:-$(cd "$(dirname "$0")/.." && pwd)}"

# Upstream source locations.  Pin WOLFSSL_REF / OPENSSL11_URL for
# reproducible runs across time.
WOLFSSL_REPO="${WOLFSSL_REPO:-https://github.com/wolfSSL/wolfssl.git}"
WOLFSSL_REF="${WOLFSSL_REF:-master}"
OPENSSL11_URL="${OPENSSL11_URL:-https://github.com/openssl/openssl/releases/download/OpenSSL_1_1_1w/openssl-1.1.1w.tar.gz}"

WOLFSSL_PREFIX="${WOLFSSL_PREFIX:-${BENCH_DIR}/install/wolfssl}"
OPENSSL11_PREFIX="${OPENSSL11_PREFIX:-${BENCH_DIR}/install/openssl11}"

CERT="${BENCH_DIR}/cert.pem"
KEY="${BENCH_DIR}/key.pem"
RESULTS_DIR="${BENCH_DIR}/results"

BIN_DIR="${BENCH_DIR}/bin"
BIN_OPENSSL3="${BIN_DIR}/iperf3-openssl3"
BIN_OPENSSL11="${BIN_DIR}/iperf3-openssl11"
BIN_WOLFSSL="${BIN_DIR}/iperf3-wolfssl"
LIB_OPENSSL3="${BIN_DIR}/openssl3-lib"
LIB_OPENSSL11="${BIN_DIR}/openssl11-lib"
LIB_WOLFSSL="${BIN_DIR}/wolfssl-lib"

# -------------------------------------------------------------- helpers
log()  { printf '\033[1;34m[bench]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

need() {
    for t in "$@"; do
        command -v "$t" >/dev/null 2>&1 || die "missing required tool: $t"
    done
}

copy_iperf_build_into() {
    local bin_dst="$1" lib_dst="$2"
    install -d "$(dirname "$bin_dst")" "$lib_dst"
    cp "${IPERF_SRC}/src/.libs/iperf3"            "$bin_dst"
    cp "${IPERF_SRC}/src/.libs/libiperf.so.0.0.0" "${lib_dst}/libiperf.so.0"
}

# ------------------------------------------------------------ preflight
# Up front we only need the tools that are used on every invocation,
# including re-runs that skip all builds.  Build-only tools are
# required lazily inside each build block.
need python3 taskset

mkdir -p "${BIN_DIR}" "${BENCH_DIR}/install" "${BENCH_DIR}/src" "${RESULTS_DIR}"

# Throwaway DTLS cert/key (reused across all runs)
if [ ! -s "$CERT" ] || [ ! -s "$KEY" ]; then
    need openssl
    log "generating throwaway DTLS cert under ${BENCH_DIR}"
    openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout "$KEY" -out "$CERT" -days 1 \
        -subj '/CN=iperf-dtls-bench' >/dev/null 2>&1
fi

# ------------------------------------------------------------ wolfSSL
WOLFSSL_SRC_DIR="${BENCH_DIR}/src/wolfssl"

if [ ! -f "${WOLFSSL_PREFIX}/lib/libwolfssl.so" ]; then
    need git autoreconf make gcc perl
    if [ ! -d "${WOLFSSL_SRC_DIR}" ]; then
        log "cloning wolfSSL ${WOLFSSL_REF} from ${WOLFSSL_REPO}"
        git clone --depth 1 --branch "${WOLFSSL_REF}" \
            "${WOLFSSL_REPO}" "${WOLFSSL_SRC_DIR}"
    fi
    log "building wolfSSL -> ${WOLFSSL_PREFIX}"
    (
        cd "${WOLFSSL_SRC_DIR}"
        [ -f configure ] || ./autogen.sh
        make distclean >/dev/null 2>&1 || true
        ./configure --prefix="${WOLFSSL_PREFIX}" \
            --enable-opensslall --enable-opensslextra --enable-dtls \
            --enable-aesgcm --enable-aesgcm-stream \
            --enable-aesni --enable-aesni-with-avx --enable-intelasm \
            --enable-sp --enable-sp-asm --enable-intelrand \
            --disable-harden --enable-sha384 --enable-sha512
        make -j"$(nproc)"
        make install
    )
else
    log "wolfSSL already present at ${WOLFSSL_PREFIX}"
fi

# ----------------------------------------------------------- OpenSSL 1.1.1
OPENSSL11_SRC_DIR="${BENCH_DIR}/src/openssl-1.1.1w"

if [ ! -f "${OPENSSL11_PREFIX}/lib/libssl.so.1.1" ]; then
    need curl make gcc perl
    log "building OpenSSL 1.1.1w -> ${OPENSSL11_PREFIX}"
    (
        cd "${BENCH_DIR}/src"
        if [ ! -d "$(basename "${OPENSSL11_SRC_DIR}")" ]; then
            [ -f openssl-1.1.1w.tar.gz ] || curl -sSLO "${OPENSSL11_URL}"
            tar -xzf openssl-1.1.1w.tar.gz
        fi
        cd "$(basename "${OPENSSL11_SRC_DIR}")"
        ./config --prefix="${OPENSSL11_PREFIX}" \
                 --openssldir="${OPENSSL11_PREFIX}/ssl" shared >/dev/null
        make -j"$(nproc)"
        make install_sw
    )
else
    log "OpenSSL 1.1.1w already present at ${OPENSSL11_PREFIX}"
fi

# ---------------------------------------------------------- iperf builds
build_iperf_variant() {
    local label="$1" configure_args="$2" bin="$3" lib="$4"
    if [ -x "$bin" ] && [ -f "${lib}/libiperf.so.0" ]; then
        log "iperf/${label} already built"
        return
    fi
    need autoreconf make gcc
    log "building iperf/${label}  (${configure_args})"
    (
        cd "${IPERF_SRC}"
        make distclean >/dev/null 2>&1 || true
        autoreconf -fi >/dev/null 2>&1
        # shellcheck disable=SC2086
        ./configure $configure_args >/dev/null
        make -j"$(nproc)" >/dev/null
    )
    copy_iperf_build_into "$bin" "$lib"
}

build_iperf_variant openssl3  "--with-openssl=/usr"                "$BIN_OPENSSL3"  "$LIB_OPENSSL3"
build_iperf_variant openssl11 "--with-openssl=${OPENSSL11_PREFIX}" "$BIN_OPENSSL11" "$LIB_OPENSSL11"
build_iperf_variant wolfssl   "--with-wolfssl=${WOLFSSL_PREFIX}"   "$BIN_WOLFSSL"   "$LIB_WOLFSSL"

# Leave the iperf tree clean on exit (configure / autoreconf regenerate
# autotools files; revert them so the user's working tree is tidy).
cleanup_iperf_tree() {
    git -C "${IPERF_SRC}" checkout -- \
        Makefile.in aclocal.m4 \
        config/compile config/config.guess config/config.sub \
        config/depcomp config/install-sh config/ltmain.sh \
        config/missing config/mkinstalldirs config/test-driver \
        configure examples/Makefile.in \
        src/Makefile.in src/iperf_config.h.in 2>/dev/null || true
}
trap cleanup_iperf_tree EXIT

# ------------------------------------------------------------ run helpers
LD_OPENSSL3="${LIB_OPENSSL3}"
LD_OPENSSL11="${LIB_OPENSSL11}:${OPENSSL11_PREFIX}/lib"
LD_WOLFSSL="${LIB_WOLFSSL}:${WOLFSSL_PREFIX}/lib"

parse_cli_json() {
    # $1 = iperf3 client JSON
    python3 - "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
end = d["end"]
cpu = end["cpu_utilization_percent"]
recv = end.get("sum_received") or end["sum"]
mbps = recv["bits_per_second"] / 1e6
lost  = end["sum"].get("lost_packets", 0) or 0
total = end["sum"].get("packets", 0) or 0
loss_pct = (100.0 * lost / total) if total else 0.0
print(f"{mbps:.1f}|{loss_pct:.2f}|"
      f"{cpu['host_user']:.1f}|{cpu['host_system']:.1f}|"
      f"{cpu['remote_user']:.1f}|{cpu['remote_system']:.1f}")
PY
}

run_once() {
    # $1 = label, $2 = tag (pin_cli / pin_srv / P=N),
    # $3 = binary, $4 = LD_LIBRARY_PATH, $5 = cli pin prefix,
    # $6 = srv pin prefix, $7 = extra cli args, $8 = "dtls" | "udp".
    local label="$1" tag="$2" bin="$3" libpath="$4"
    local cli_pin="$5" srv_pin="$6" extra_cli="$7" proto="$8"
    local port=$((18000 + RANDOM % 1000))
    local cli_json="${RESULTS_DIR}/${label}_${tag}_cli.json"
    local srv_json="${RESULTS_DIR}/${label}_${tag}_srv.json"
    local cli_err="${RESULTS_DIR}/${label}_${tag}_cli.err"
    local srv_err="${RESULTS_DIR}/${label}_${tag}_srv.err"
    local srv_args cli_args
    if [ "$proto" = "dtls" ]; then
        srv_args=(-s -p "$port" -J --dtls --dtls-cert "$CERT" --dtls-key "$KEY" -1)
        cli_args=(-c 127.0.0.1 -p "$port" -J --dtls -l "$BLKSZ" -b 0 -t "$DUR" $extra_cli)
    else
        srv_args=(-s -p "$port" -J -1)
        cli_args=(-c 127.0.0.1 -p "$port" -J -u -l "$BLKSZ" -b 0 -t "$DUR" $extra_cli)
    fi
    LD_LIBRARY_PATH="$libpath" $srv_pin "$bin" "${srv_args[@]}" >"$srv_json" 2>"$srv_err" &
    local pid=$!
    sleep 0.6
    # Can't use `cmd; rc=$?` under `set -e` -- a non-zero exit aborts
    # the script *before* the rc assignment runs, and the caller never
    # sees the failure.  Explicitly tolerate failure on this line.
    local rc=0
    LD_LIBRARY_PATH="$libpath" $cli_pin "$bin" "${cli_args[@]}" \
        >"$cli_json" 2>"$cli_err" || rc=$?
    wait "$pid" 2>/dev/null || true
    if [ "$rc" -ne 0 ] || [ ! -s "$cli_json" ]; then
        printf '%-16s %-8s  CLIENT FAILED (rc=%d)\n' "$label" "$tag" "$rc"
        # Surface the first few lines of whatever each side wrote to
        # stderr.  Use `head | sed` (not `sed | head`) so the consumer
        # end of the pipe closes first; otherwise on a long error file
        # sed gets SIGPIPE, pipefail propagates non-zero, and the
        # enclosing `set -e` would kill the whole sweep before we reach
        # the `return 0` below.
        if [ -s "$cli_err" ]; then
            head -n 5 "$cli_err" | sed 's/^/    cli-stderr: /'
        fi
        if [ -s "$srv_err" ]; then
            head -n 5 "$srv_err" | sed 's/^/    srv-stderr: /'
        fi
        return 0
    fi
    local line
    line=$(parse_cli_json "$cli_json" 2>/dev/null) || line="ERR|0|0|0|0|0"
    IFS='|' read -r mbps loss ucli scli usrv ssrv <<<"$line"
    printf '%-16s %-8s  %9.1f Mbps   loss %5s%%   cli %6.1f%%u + %6.1f%%s (=%7.1f%%)   srv %6.1f%%u + %6.1f%%s (=%7.1f%%)\n' \
        "$label" "$tag" "$mbps" "$loss" \
        "$ucli" "$scli" "$(python3 -c "print($ucli+$scli)")" \
        "$usrv" "$ssrv" "$(python3 -c "print($usrv+$ssrv)")"
}

# --------------------------------------------------------- pinned sweep
run_pinned_sweep() {
    log "pinned single-core sweep (DUR=${DUR}s, BLKSZ=${BLKSZ})"
    printf '%-16s %-8s  %14s   %-12s   %-46s   %s\n' \
        label scenario throughput loss 'client CPU' 'server CPU'
    echo "# ---------------------------------------------------------------------------------------------------------------------------------"
    for scn in pin_cli pin_srv; do
        local cpin="" spin=""
        case "$scn" in
            pin_cli) cpin="taskset -c 0" ;;
            pin_srv) spin="taskset -c 0" ;;
        esac
        run_once udp-plain        "$scn" "$BIN_OPENSSL3"  "$LD_OPENSSL3"  "$cpin" "$spin" "" udp
        run_once dtls-openssl3    "$scn" "$BIN_OPENSSL3"  "$LD_OPENSSL3"  "$cpin" "$spin" "" dtls
        run_once dtls-openssl111  "$scn" "$BIN_OPENSSL11" "$LD_OPENSSL11" "$cpin" "$spin" "" dtls
        run_once dtls-wolfssl     "$scn" "$BIN_WOLFSSL"   "$LD_WOLFSSL"   "$cpin" "$spin" "" dtls
        echo
    done
}

# -------------------------------------------------------- parallel sweep
run_parallel_sweep() {
    log "multi-thread sweep (DUR=${DUR}s, BLKSZ=${BLKSZ}, PARALLELS=${PARALLELS})"
    printf '%-16s %-8s  %14s   %-12s   %-46s   %s\n' \
        label threads throughput loss 'client CPU' 'server CPU'
    echo "# ---------------------------------------------------------------------------------------------------------------------------------"
    for P in $PARALLELS; do
        run_once udp-plain        "P=${P}" "$BIN_OPENSSL3"  "$LD_OPENSSL3"  "" "" "-P $P" udp
        run_once dtls-openssl3    "P=${P}" "$BIN_OPENSSL3"  "$LD_OPENSSL3"  "" "" "-P $P" dtls
        run_once dtls-openssl111  "P=${P}" "$BIN_OPENSSL11" "$LD_OPENSSL11" "" "" "-P $P" dtls
        run_once dtls-wolfssl     "P=${P}" "$BIN_WOLFSSL"   "$LD_WOLFSSL"   "" "" "-P $P" dtls
        echo
    done
}

# --------------------------------------------------------- DTLS preflight
preflight_dtls_stack() {
    local label="$1" bin="$2" libpath="$3"
    local DUR_SAVED="$DUR"
    DUR=2
    log "preflight: ${label}"
    run_once "preflight-${label}" "smoke" "$bin" "$libpath" "" "" "" dtls >/dev/null \
        || true
    DUR="$DUR_SAVED"
    local cli_json="${RESULTS_DIR}/preflight-${label}_smoke_cli.json"
    if [ ! -s "$cli_json" ]; then
        warn "${label}: no client JSON produced -- stack may be broken"
        # `head | sed` (not `sed | head`): see note in run_once.
        if [ -s "${RESULTS_DIR}/preflight-${label}_smoke_cli.err" ]; then
            head -n 8 "${RESULTS_DIR}/preflight-${label}_smoke_cli.err" \
                | sed 's/^/    cli-stderr: /'
        fi
        if [ -s "${RESULTS_DIR}/preflight-${label}_smoke_srv.err" ]; then
            head -n 8 "${RESULTS_DIR}/preflight-${label}_smoke_srv.err" \
                | sed 's/^/    srv-stderr: /'
        fi
        return 1
    fi
    return 0
}

# -------------------------------------------------------------------- main
log "host: $(nproc) logical cores"
log "bench dir: ${BENCH_DIR}"
echo

if [ "${SKIP_PREFLIGHT:-0}" != 1 ]; then
    preflight_dtls_stack dtls-openssl3    "$BIN_OPENSSL3"  "$LD_OPENSSL3"   || true
    preflight_dtls_stack dtls-openssl111  "$BIN_OPENSSL11" "$LD_OPENSSL11"  || true
    preflight_dtls_stack dtls-wolfssl     "$BIN_WOLFSSL"   "$LD_WOLFSSL"    || true
    echo
fi

[ "${SKIP_PINNED:-0}" = 1 ]   || run_pinned_sweep
[ "${SKIP_PARALLEL:-0}" = 1 ] || run_parallel_sweep

log "done. raw per-run JSON kept in ${RESULTS_DIR}/"
log "re-run with BENCH_DIR=${BENCH_DIR} to skip the rebuilds."
