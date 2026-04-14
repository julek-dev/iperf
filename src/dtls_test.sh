#!/bin/sh
# dtls_test.sh -- smoke test the iperf DTLS 1.2 data path end-to-end.
#
# Skips quietly when the binary wasn't built with --dtls support
# (HAVE_DTLS undefined), so it's safe to wire into `make check`
# regardless of configure options.

set -eu

IPERF=${IPERF:-./iperf3}
PORT=${DTLS_TEST_PORT:-15297}
TMP=$(mktemp -d)
SRV=""
trap 'rm -rf "$TMP"; [ -n "$SRV" ] && kill "$SRV" 2>/dev/null || true' EXIT INT TERM

# If --dtls isn't compiled in, this build doesn't need to test it.
if ! "$IPERF" --help 2>&1 | grep -q -- "--dtls"; then
    echo "dtls_test: --dtls not compiled in -- skipping"
    exit 77    # automake SKIP
fi

# Generate a throwaway self-signed cert.
if ! command -v openssl >/dev/null 2>&1; then
    echo "dtls_test: openssl(1) not available -- skipping"
    exit 77
fi
openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 1 -subj '/CN=iperf-dtls-test' >/dev/null 2>&1

"$IPERF" -s -p "$PORT" \
         --dtls --dtls-cert "$TMP/cert.pem" --dtls-key "$TMP/key.pem" \
         -1 > "$TMP/srv.log" 2>&1 &
SRV=$!

# Give the server a moment to bind.
sleep 1

"$IPERF" -c 127.0.0.1 -p "$PORT" --dtls -t 2 -l 1200 -b 5M \
         > "$TMP/cli.log" 2>&1
rc=$?

wait $SRV 2>/dev/null || true

if [ "$rc" -ne 0 ]; then
    echo "dtls_test: client exited with $rc"
    echo "--- client ---"; cat "$TMP/cli.log"
    echo "--- server ---"; cat "$TMP/srv.log"
    exit 1
fi

# Sanity-check the output: at least some bytes must flow and no datagrams lost.
if ! grep -q "sender" "$TMP/cli.log" || ! grep -q "receiver" "$TMP/cli.log"; then
    echo "dtls_test: client output missing sender/receiver rows"
    cat "$TMP/cli.log"
    exit 1
fi
if ! grep -q "0/.* (0%)" "$TMP/cli.log"; then
    echo "dtls_test: unexpected datagram loss"
    cat "$TMP/cli.log"
    exit 1
fi

echo "dtls_test: OK"
exit 0
