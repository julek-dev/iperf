# DTLS 1.2 performance-benchmark scripts

Reproducible loopback benchmark for iperf's `--dtls` data path against
three SSL/TLS stacks:

- **Distro OpenSSL 3** (whatever `libssl-dev` provides)
- **OpenSSL 1.1.1w**, built from upstream
- **wolfSSL**, built from upstream with Intel AES-NI / AVX / AVX-512 /
  PCLMULQDQ / AES-GCM streaming enabled

Plus a baseline plain-UDP row so you can see the DTLS-over-UDP tax.

All benchmarks happen on the host's loopback interface (`127.0.0.1`); no
real NIC is touched. The point is to measure per-core crypto + framing
throughput, not network.

---

## Files

| File | What it is |
|------|------------|
| `benchmark-dtls.sh`       | Fully self-contained reproducer. Pulls wolfSSL + OpenSSL 1.1.1w from upstream into `$BENCH_DIR`, builds three iperf3 variants, runs the sweeps, prints a table. |
| `benchmark-dtls-bwrap.sh` | Thin wrapper that runs `benchmark-dtls.sh` inside a `bubblewrap(1)` sandbox so nothing is written outside `$PWD` / the iperf repo. |

---

## Quick start

```sh
git clone https://github.com/julek-dev/iperf
cd iperf
git checkout claude/dtls-performance-testing-uG1IV
./scripts/benchmark-dtls.sh
```

The first invocation takes ~5–10 minutes on a modern x86-64 host: it
clones wolfSSL, downloads OpenSSL 1.1.1w, builds both plus three iperf3
variants, then runs the full sweep. Subsequent invocations reuse the
cached build tree (see `BENCH_DIR` below).

Quick sanity check (~1 min):

```sh
DUR=5 PARALLELS="1 4" ./scripts/benchmark-dtls.sh
```

Sandboxed version — nothing written outside the current directory:

```sh
./scripts/benchmark-dtls-bwrap.sh          # artefacts land under ./dtls-bench
```

---

## What you'll see

After builds complete, the script prints a freshness check, a preflight
per DTLS stack, then two sweeps:

```
[bench] host: 16 logical cores
[bench] bench dir: /tmp/iperf-dtls-bench.abc123
[bench] iperf source HEAD:  bfe9131  (bench: add PERF_RECORD=1 ...)
[bench] iperf/openssl3:  binary contains DTLS fix-v2 marker (rebuild OK)
[bench] iperf/openssl11: binary contains DTLS fix-v2 marker (rebuild OK)
[bench] iperf/wolfssl:   binary contains DTLS fix-v2 marker (rebuild OK)

[bench] preflight: dtls-openssl3
[bench] preflight: dtls-openssl111
[bench] preflight: dtls-wolfssl

[bench] pinned single-core sweep (DUR=30s, BLKSZ=1200)
label            scenario      throughput    loss     client CPU                     server CPU
# ---------------------------------------------------------------------------------------------
udp-plain        pin_cli        812.0 Mbps   0.00%   cli  99.4% (55.4% u + 44.0% s)  srv  95.3%
dtls-openssl3    pin_cli        740.2 Mbps   0.00%   cli  99.4% (58.1% u + 41.3% s)  srv  96.2%
dtls-openssl111  pin_cli        727.3 Mbps   0.00%   cli  99.4% (59.0% u + 40.4% s)  srv  96.0%
dtls-wolfssl     pin_cli        793.6 Mbps   0.00%   cli  99.4% (61.2% u + 38.2% s)  srv  96.5%

udp-plain        pin_srv        ...

[bench] multi-thread sweep (DUR=30s, BLKSZ=1200, PARALLELS=1 2 4 8)
label            threads       throughput    loss     client CPU                     server CPU
# ---------------------------------------------------------------------------------------------
udp-plain        P=1            888.5 Mbps   ...
dtls-openssl3    P=1            804.9 Mbps   ...
...
dtls-wolfssl     P=8           1039.0 Mbps   ...

[bench] done. raw per-run JSON kept in /tmp/iperf-dtls-bench.abc123/results/
[bench] re-run with BENCH_DIR=/tmp/iperf-dtls-bench.abc123 to skip the rebuilds.
```

Per-run iperf3 JSON is kept under `$BENCH_DIR/results/` so you can pull
specific fields out afterwards.

---

## Scenarios

### Pinned single-core sweep

| tag | what it does |
|-----|--------------|
| `pin_cli` | client pinned to core 0 (`taskset -c 0`), server free |
| `pin_srv` | server pinned to core 0, client free |

In both rows the pinned side shows ~99 % of one core — it's the
bottleneck. This is the most sensitive measurement of per-core crypto
throughput.

### Multi-thread sweep (`-P N`)

For each value in `$PARALLELS` (default `1 2 4 8`), iperf3 is run with
`-P N`. Each of the N parallel streams gets its own pthread on both
sides, letting the kernel spread workers across multiple cores.
Throughput typically scales sub-linearly because loopback is a single
in-kernel pipe.

---

## Environment knobs

| Variable | Default | What it does |
|----------|---------|--------------|
| `DUR` | `30` | Seconds each iperf3 run lasts. |
| `BLKSZ` | `1200` | UDP/DTLS payload size per datagram. Keep ≤ 1400 so it fits in MTU after DTLS overhead. |
| `PARALLELS` | `"1 2 4 8"` | Space-separated list of `-P` values for the multi-thread sweep. |
| `BENCH_DIR` | fresh `mktemp -d` | Where build output + per-run JSON land. Set to a persistent path to reuse builds across invocations. |
| `IPERF_SRC` | `..` from the script | Location of the iperf source tree. The script auto-detects. |
| `WOLFSSL_REPO` | `https://github.com/wolfSSL/wolfssl.git` | Override to a fork. |
| `WOLFSSL_REF` | `v5.8.4-stable` | Git ref to check out. Use `master` for tip-of-tree. |
| `OPENSSL11_URL` | GitHub release tarball | Override to pin a different 1.1.1 patch. |
| `WOLFSSL_CFLAGS` | `-march=native` | Extra CFLAGS for the wolfSSL build. Set to `""` on pre-Haswell or non-x86 hosts. |
| `SKIP_PREFLIGHT` | `0` | `1` skips the per-stack 2-second smoke test. |
| `SKIP_PINNED`   | `0` | `1` skips the pinned-core sweep. |
| `SKIP_PARALLEL` | `0` | `1` skips the multi-thread sweep. |
| `PERF_RECORD` | `0` | `1` wraps the pinned side with `perf record`; see below. |
| `PERF_ARGS` | `-F 999 --call-graph fp` | Args passed to `perf record`. |
| `IPERF_DTLS_DEBUG` | unset | When set, each iperf3 run prints an internal marker line to stderr (into the per-run `.err` file). Useful for verifying that the binary contains a specific fix. |

Common combinations:

```sh
# Quick iteration — reuse a cached build tree, just re-run benchmarks:
BENCH_DIR=~/dtls-bench DUR=10 PARALLELS="1 4" ./scripts/benchmark-dtls.sh

# Just the pinned sweep:
SKIP_PARALLEL=1 ./scripts/benchmark-dtls.sh

# Just the multi-thread sweep:
SKIP_PINNED=1 ./scripts/benchmark-dtls.sh

# Byte-reproducible: pin wolfSSL to a specific tag, use a fixed BENCH_DIR:
WOLFSSL_REF=v5.8.4-stable BENCH_DIR=~/dtls-bench-v584 \
    ./scripts/benchmark-dtls.sh
```

---

## CPU profiling with perf(1)

Set `PERF_RECORD=1` and the pinned side of every pinned-sweep row is
recorded under `perf(1)`. `.perf.data` files land next to the JSON in
`$BENCH_DIR/results/`.

```sh
PERF_RECORD=1 SKIP_PARALLEL=1 DUR=60 ./scripts/benchmark-dtls.sh
```

The script prints the file list + copy-pasteable analysis commands at
the end:

```
[bench] perf captures (8):
    .../dtls-openssl3_pin_cli_cli.perf.data    (7.8M)
    .../dtls-openssl111_pin_cli_cli.perf.data  (8.1M)
    .../dtls-wolfssl_pin_cli_cli.perf.data     (8.0M)
    .../udp-plain_pin_cli_cli.perf.data        (5.2M)
    ... pin_srv too ...
[bench] analyse with:
    perf report      -i .../dtls-wolfssl_pin_cli_cli.perf.data
    perf annotate    -i .../dtls-wolfssl_pin_cli_cli.perf.data
    perf script      -i .../dtls-wolfssl_pin_cli_cli.perf.data  # raw samples for FlameGraph etc.
```

### Switching call-graph unwinder

Default `-F 999 --call-graph fp` is cheap and good enough for
iperf-internal profiling (iperf is built with frame pointers). For
unwinding into `libssl` / `libwolfssl` you usually want DWARF:

```sh
PERF_RECORD=1 PERF_ARGS='-F 999 --call-graph dwarf' \
    SKIP_PARALLEL=1 DUR=60 ./scripts/benchmark-dtls.sh
```

### PMU events instead of CPU cycles

```sh
PERF_RECORD=1 PERF_ARGS='-F 999 -e cycles:u,instructions:u,cache-misses:u' \
    SKIP_PARALLEL=1 DUR=30 ./scripts/benchmark-dtls.sh
```

### Flamegraph

```sh
# Once you have a .perf.data:
perf script -i <results>/dtls-wolfssl_pin_cli_cli.perf.data \
  | stackcollapse-perf.pl \
  | flamegraph.pl > wolfssl.svg
```

### Requirements for perf

- `apt install linux-tools-generic` (Debian/Ubuntu) or `dnf install perf` (Fedora/RHEL).
- `kernel.perf_event_paranoid ≤ 2` for non-root user-level sampling, or run as root. The script warns if it's higher.
- For meaningful DWARF unwinding into SSL libraries, rebuild them with
  `CFLAGS="-fno-omit-frame-pointer -g"`. The default wolfSSL/OpenSSL
  packages from distros are usually good enough.

---

## Sandboxed execution (`benchmark-dtls-bwrap.sh`)

Wraps the main script with `bubblewrap(1)` so every write lands inside
one of two directories:

1. `$BENCH_DIR` (default `$PWD/dtls-bench`) — benchmark artefacts
2. `$IPERF_ROOT` — auto-detected, needed because `./configure` and
   `autoreconf` regenerate files in-tree during each iperf variant build

Everything else (`/usr`, `/lib`, `/etc`, `/var`, the rest of `/home`)
is read-only or unreachable. Writes to `/tmp` land in an in-sandbox
tmpfs that's wiped on exit.

```sh
# From any directory; output lands under ./dtls-bench
cd ~/somewhere
/path/to/iperf/scripts/benchmark-dtls-bwrap.sh

# All the same env knobs work:
DUR=10 PARALLELS="1 4" /path/to/iperf/scripts/benchmark-dtls-bwrap.sh
PERF_RECORD=1 SKIP_PARALLEL=1 /path/to/iperf/scripts/benchmark-dtls-bwrap.sh
```

Requires `bubblewrap` installed (`apt install bubblewrap` /
`dnf install bubblewrap`). The underlying build tools still need to be
on the host — bwrap only restricts writes, not toolchain access.

Network is shared with the host (`--share-net`) because `git clone`
and `curl` need internet for the first-time wolfSSL/OpenSSL fetches.

---

## Host prerequisites

Ubuntu 24.04 example:

```sh
sudo apt install -y \
    build-essential autoconf automake libtool pkg-config \
    libssl-dev openssl \
    git curl python3 util-linux \
    bubblewrap                    # only needed for the bwrap wrapper
    linux-tools-generic           # only needed for PERF_RECORD=1
```

- Host CPU: x86-64 with AES-NI is assumed. The default
  `WOLFSSL_CFLAGS=-march=native` also exploits AVX, AVX2, AVX-512,
  VAES, VPCLMULQDQ, and RDSEED when present. On pre-Haswell hosts
  set `WOLFSSL_CFLAGS=""`.
- Free disk: ~400 MB under `$BENCH_DIR` for the build tree + per-run
  JSON + `.perf.data` files.
- Kernel `net.core.rmem_max` / `wmem_max` don't need tuning — loopback
  is fast enough for steady-state DTLS.

---

## Results layout

```
$BENCH_DIR/
├── cert.pem, key.pem              # throwaway RSA cert for DTLS server
├── src/                           # wolfSSL + OpenSSL 1.1.1w source trees
├── install/
│   ├── wolfssl/                   # prefix with libwolfssl + headers
│   └── openssl11/                 # prefix with libssl.so.1.1 + headers
├── bin/                           # per-variant iperf3 binaries
│   ├── iperf3-openssl3,  openssl3-lib/libiperf.so.0
│   ├── iperf3-openssl11, openssl11-lib/libiperf.so.0
│   └── iperf3-wolfssl,   wolfssl-lib/libiperf.so.0
└── results/                       # per-run outputs
    ├── <label>_<tag>_cli.json      # iperf3 client JSON
    ├── <label>_<tag>_srv.json      # iperf3 server JSON
    ├── <label>_<tag>_cli.err       # client stderr (incl. DTLS error details)
    ├── <label>_<tag>_srv.err       # server stderr
    └── <label>_<tag>_<side>.perf.data   # only when PERF_RECORD=1
```

---

## Troubleshooting

### "iperf/wolfssl: binary MISSING DTLS fix-v2 marker"

Your `$BENCH_DIR/bin/iperf3-wolfssl` is stale — it was built from older
iperf source before a fix went in. The harness's idempotency check
sees the file and skips the rebuild. Force a fresh build:

```sh
rm -rf $BENCH_DIR/bin/iperf3-wolfssl $BENCH_DIR/bin/wolfssl-lib
./scripts/benchmark-dtls.sh
```

### "CLIENT FAILED (rc=…)"

The row's stderr snippet is printed inline, and the full stderr is at
`$BENCH_DIR/results/<label>_<tag>_{cli,srv}.err`. Common causes:

- **`SSL_get_error=-308 errno=22`** from wolfSSL with no `fix-v2`
  marker: stale binary (see above).
- **`SSL_get_error=-308 errno=22`** *with* the `fix-v2` marker: likely
  a wolfSSL build missing `--enable-ipv6` (we inject that by default
  now, but a custom `WOLFSSL_SRC` / manual install might not).
- **`Cannot assign requested address`**: another process is using the
  ephemeral port; just re-run.

### `perf: No such device`

The kernel isn't exposing `perf_event_open` (common in unprivileged
containers / some VMs). Either run on the host directly or drop
`PERF_RECORD=1`.

### "`bwrap not installed`"

Install bubblewrap: `apt install bubblewrap` or `dnf install bubblewrap`.

### Results look suspiciously high (>10 Gbps on UDP)

You're probably on a big Intel Xeon or similar. Loopback throughput on
modern NUMA systems can easily hit 40+ Gbps. If the numbers swing a lot
between runs, pin to a specific core group with `taskset` or use the
multi-thread sweep to average across cores.
