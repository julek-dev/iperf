/*
 * iperf_dtls.c -- DTLS 1.2 data-plane protocol for iperf.
 *
 * This file is written against the OpenSSL API and must not contain
 * any wolfSSL-specific identifiers.  When iperf is built with
 * --with-wolfssl the build system forces -include wolfssl/options.h
 * before every translation unit so <openssl/...> resolves to
 * wolfSSL's OpenSSL compatibility shims.
 *
 * The DTLS protocol wraps iperf's existing UDP data path.  Streams
 * use the same packet-framing as iperf_udp.c (sec/usec/pcount header)
 * so jitter and loss accounting is identical; the only difference is
 * that read/write goes through SSL_read/SSL_write instead of
 * recv()/send().
 *
 * Copyright (c) 2026, The Regents of the University of California
 * through Lawrence Berkeley National Laboratory.  BSD-style license,
 * see LICENSE.
 */
#include "iperf_config.h"

#if defined(HAVE_DTLS)

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <netinet/in.h>
#include <stdint.h>
#include <inttypes.h>
#include <sys/time.h>

#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/bio.h>
#include <openssl/rand.h>
#include <openssl/hmac.h>

#include "iperf.h"
#include "iperf_api.h"
#include "iperf_util.h"
#include "iperf_dtls.h"
#include "iperf_time.h"
#include "timer.h"
#include "net.h"

#ifdef HAVE_DTLS_COOKIES
#define DTLS_COOKIE_SECRET_LEN 16
#define DTLS_COOKIE_MAX_LEN 32

static unsigned char dtls_cookie_secret[DTLS_COOKIE_SECRET_LEN];
static int dtls_cookie_secret_initialized = 0;
#endif

static void
dtls_report_error(const char *where)
{
    unsigned long e;
    char buf[256];
    while ((e = ERR_get_error()) != 0) {
        ERR_error_string_n(e, buf, sizeof(buf));
        fprintf(stderr, "iperf DTLS: %s: %s\n", where, buf);
    }
}

/*
 * Extended error reporter for SSL_accept / SSL_connect failures.
 * Prints the SSL_get_error category (so the caller can distinguish
 * SSL_ERROR_WANT_READ vs. SSL_ERROR_SYSCALL vs. SSL_ERROR_SSL etc.),
 * errno, and dumps the full error queue via ERR_print_errors_fp.
 * This is considerably more informative than the single "error state
 * on socket" string that some OpenSSL-compatible libraries return as
 * their default stringification of an unspecified SSL failure.
 */
static void
dtls_report_ssl_error(const char *where, SSL *ssl, int rc)
{
    int saved_errno = errno;
    int sslerr = ssl ? SSL_get_error(ssl, rc) : -1;
    fprintf(stderr,
            "iperf DTLS: %s failed: rc=%d SSL_get_error=%d errno=%d (%s)\n",
            where, rc, sslerr, saved_errno, strerror(saved_errno));
    ERR_print_errors_fp(stderr);
    /* Also drain the error queue via the older API for back-compat. */
    dtls_report_error(where);
}

#ifdef HAVE_DTLS_COOKIES
static int
dtls_build_cookie(SSL *ssl, unsigned char *cookie, unsigned int *cookie_len)
{
    union {
        struct sockaddr sa;
        struct sockaddr_in s4;
        struct sockaddr_in6 s6;
        struct sockaddr_storage ss;
    } peer;
    unsigned int len = 0;
    unsigned int hmac_len = 0;
    unsigned char result[EVP_MAX_MD_SIZE];
    BIO *bio;

    if (!dtls_cookie_secret_initialized) {
        if (RAND_bytes(dtls_cookie_secret, DTLS_COOKIE_SECRET_LEN) != 1)
            return 0;
        dtls_cookie_secret_initialized = 1;
    }

    bio = SSL_get_rbio(ssl);
    if (!bio)
        return 0;
    memset(&peer, 0, sizeof(peer));
    (void) BIO_dgram_get_peer(bio, &peer);

    if (peer.sa.sa_family == AF_INET) {
        len = sizeof(peer.s4.sin_port) + sizeof(peer.s4.sin_addr);
    } else if (peer.sa.sa_family == AF_INET6) {
        len = sizeof(peer.s6.sin6_port) + sizeof(peer.s6.sin6_addr);
    } else {
        return 0;
    }

    {
        unsigned char buf[sizeof(peer)];
        unsigned char *p = buf;
        if (peer.sa.sa_family == AF_INET) {
            memcpy(p, &peer.s4.sin_port, sizeof(peer.s4.sin_port));
            p += sizeof(peer.s4.sin_port);
            memcpy(p, &peer.s4.sin_addr, sizeof(peer.s4.sin_addr));
        } else {
            memcpy(p, &peer.s6.sin6_port, sizeof(peer.s6.sin6_port));
            p += sizeof(peer.s6.sin6_port);
            memcpy(p, &peer.s6.sin6_addr, sizeof(peer.s6.sin6_addr));
        }
        if (!HMAC(EVP_sha256(),
                  dtls_cookie_secret, DTLS_COOKIE_SECRET_LEN,
                  buf, len, result, &hmac_len))
            return 0;
    }

    if (hmac_len > DTLS_COOKIE_MAX_LEN)
        hmac_len = DTLS_COOKIE_MAX_LEN;
    memcpy(cookie, result, hmac_len);
    *cookie_len = hmac_len;
    return 1;
}

static int
dtls_generate_cookie(SSL *ssl, unsigned char *cookie, unsigned int *cookie_len)
{
    return dtls_build_cookie(ssl, cookie, cookie_len);
}

static int
dtls_verify_cookie(SSL *ssl, const unsigned char *cookie, unsigned int cookie_len)
{
    unsigned char expected[DTLS_COOKIE_MAX_LEN];
    unsigned int expected_len = 0;
    if (!dtls_build_cookie(ssl, expected, &expected_len))
        return 0;
    if (expected_len != cookie_len)
        return 0;
    return memcmp(expected, cookie, cookie_len) == 0 ? 1 : 0;
}
#endif /* HAVE_DTLS_COOKIES */

/*
 * One-shot OpenSSL initialization.  OpenSSL 1.1.0+ auto-initializes,
 * so this is effectively a safe no-op after the first call.
 */
static void
dtls_openssl_init(void)
{
    static int done = 0;
    if (done)
        return;
    done = 1;
    SSL_library_init();
    SSL_load_error_strings();
    OpenSSL_add_all_algorithms();
}

int
iperf_dtls_ctx_init(struct iperf_test *test, int server_side)
{
    SSL_CTX *ctx;

    if (test->dtls_ctx != NULL)
        return 0;

    dtls_openssl_init();

    ctx = SSL_CTX_new(DTLS_method());
    if (!ctx) {
        dtls_report_error("SSL_CTX_new(DTLS_method)");
        i_errno = IEDTLSCTX;
        return -1;
    }

    /* Pin to DTLS 1.2. */
    SSL_CTX_set_min_proto_version(ctx, DTLS1_2_VERSION);
    SSL_CTX_set_max_proto_version(ctx, DTLS1_2_VERSION);

    SSL_CTX_set_read_ahead(ctx, 1);

    if (server_side) {
        if (!test->settings->dtls_cert || !test->settings->dtls_key) {
            i_errno = IEDTLSMISSINGCERT;
            SSL_CTX_free(ctx);
            return -1;
        }
        if (SSL_CTX_use_certificate_file(ctx, test->settings->dtls_cert,
                                         SSL_FILETYPE_PEM) != 1) {
            dtls_report_error("SSL_CTX_use_certificate_file");
            SSL_CTX_free(ctx);
            i_errno = IEDTLSCERT;
            return -1;
        }
        if (SSL_CTX_use_PrivateKey_file(ctx, test->settings->dtls_key,
                                        SSL_FILETYPE_PEM) != 1) {
            dtls_report_error("SSL_CTX_use_PrivateKey_file");
            SSL_CTX_free(ctx);
            i_errno = IEDTLSKEY;
            return -1;
        }
#ifdef HAVE_DTLS_COOKIES
        SSL_CTX_set_cookie_generate_cb(ctx, dtls_generate_cookie);
        SSL_CTX_set_cookie_verify_cb(ctx, dtls_verify_cookie);
#endif
        /* Performance test: skip peer cert verification by default. */
        SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, NULL);
    } else {
        /* Client */
        if (test->settings->dtls_ca) {
            if (SSL_CTX_load_verify_locations(ctx, test->settings->dtls_ca,
                                              NULL) != 1) {
                dtls_report_error("SSL_CTX_load_verify_locations");
                SSL_CTX_free(ctx);
                i_errno = IEDTLSCERT;
                return -1;
            }
            SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);
        } else {
            /* Performance test: don't require trust anchor. */
            SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, NULL);
        }
    }

    test->dtls_ctx = (void *) ctx;
    return 0;
}

void
iperf_dtls_ctx_free(struct iperf_test *test)
{
    if (test->dtls_ctx) {
        SSL_CTX_free((SSL_CTX *) test->dtls_ctx);
        test->dtls_ctx = NULL;
    }
    if (test->dtls_pending_ssl) {
        SSL_free((SSL *) test->dtls_pending_ssl);
        test->dtls_pending_ssl = NULL;
    }
}

void
iperf_dtls_stream_free(struct iperf_stream *sp)
{
    if (sp && sp->ssl) {
        SSL_shutdown((SSL *) sp->ssl);
        SSL_free((SSL *) sp->ssl);
        sp->ssl = NULL;
    }
}

/*
 * iperf_dtls_listen -- open the server UDP listening socket.  DTLS
 * handshake is deferred to iperf_dtls_accept.
 */
int
iperf_dtls_listen(struct iperf_test *test)
{
    int s;

    if (iperf_dtls_ctx_init(test, /*server_side=*/1) < 0)
        return -1;

    if ((s = netannounce(test->settings->domain, Pudp,
                         test->bind_address, test->bind_dev,
                         test->server_port)) < 0) {
        i_errno = IESTREAMLISTEN;
        return -1;
    }
    return s;
}

/*
 * iperf_dtls_accept -- do DTLS cookie exchange + handshake with a
 * single client.  Follows the same socket-juggling pattern as
 * iperf_udp_accept (peek-then-connect + reopen the listener).
 */
int
iperf_dtls_accept(struct iperf_test *test)
{
    struct sockaddr_storage sa_peer;
    socklen_t sa_len = sizeof(sa_peer);
    int s;
    SSL *ssl = NULL;
    BIO *bio = NULL;
    struct timeval tv;
    char peekbuf[1];

    s = test->prot_listener;

    /* Peek the first datagram (the ClientHello) to learn the peer's
     * address, then connect() the socket and hand it to SSL_accept.
     * SSL_accept drives the cookie exchange via the callbacks we set
     * on the SSL_CTX, so DTLSv1_listen is not required -- which is
     * important because not every OpenSSL-compat implementation
     * exposes it.  (Performance-test scenario: we don't need the
     * DoS-resistance shortcut DTLSv1_listen provides.)
     */
    memset(&sa_peer, 0, sa_len);
    if (recvfrom(s, peekbuf, sizeof(peekbuf), MSG_PEEK,
                 (struct sockaddr *) &sa_peer, &sa_len) < 0) {
        i_errno = IESTREAMACCEPT;
        return -1;
    }

    if (connect(s, (struct sockaddr *) &sa_peer, sa_len) < 0) {
        i_errno = IESTREAMACCEPT;
        return -1;
    }

    /* Bound SSL_accept so a stray client can't wedge us. */
    tv.tv_sec = 30;
    tv.tv_usec = 0;
    (void) setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    bio = BIO_new_dgram(s, BIO_NOCLOSE);
    if (!bio) {
        dtls_report_error("BIO_new_dgram");
        i_errno = IESTREAMACCEPT;
        return -1;
    }
    (void) BIO_ctrl(bio, BIO_CTRL_DGRAM_SET_CONNECTED, 0, &sa_peer);

    ssl = SSL_new((SSL_CTX *) test->dtls_ctx);
    if (!ssl) {
        dtls_report_error("SSL_new");
        BIO_free(bio);
        i_errno = IESTREAMACCEPT;
        return -1;
    }
    SSL_set_bio(ssl, bio, bio);
#ifdef HAVE_DTLS_COOKIES
    SSL_set_options(ssl, SSL_OP_COOKIE_EXCHANGE);
#endif

    {
        int arc = SSL_accept(ssl);
        if (arc <= 0) {
            dtls_report_ssl_error("SSL_accept", ssl, arc);
            SSL_free(ssl);
            i_errno = IEDTLSHANDSHAKE;
            return -1;
        }
    }

    /* Replace the listening socket (matches iperf_udp_accept). */
    FD_CLR(test->prot_listener, &test->read_set);
    test->prot_listener = netannounce(test->settings->domain, Pudp,
                                      test->bind_address, test->bind_dev,
                                      test->server_port);
    if (test->prot_listener < 0) {
        SSL_free(ssl);
        i_errno = IESTREAMLISTEN;
        return -1;
    }
    FD_SET(test->prot_listener, &test->read_set);
    if (test->max_fd < test->prot_listener)
        test->max_fd = test->prot_listener;

    /* Send the UDP_CONNECT_REPLY sync packet (wrapped in DTLS). */
    {
        unsigned int reply = UDP_CONNECT_REPLY;
        if (SSL_write(ssl, &reply, sizeof(reply)) <= 0) {
            dtls_report_error("SSL_write(reply)");
            SSL_free(ssl);
            i_errno = IEDTLSWRITE;
            return -1;
        }
    }

    /* Hand the SSL* off to the next newly-created stream. */
    test->dtls_pending_ssl = ssl;
    return s;
}

/*
 * iperf_dtls_connect -- client side.  Open a connected UDP socket and
 * drive the DTLS handshake to completion.
 */
int
iperf_dtls_connect(struct iperf_test *test)
{
    int s;
    SSL *ssl = NULL;
    BIO *bio = NULL;
    struct sockaddr_storage peer;
    socklen_t peerlen = sizeof(peer);
    struct timeval tv;
    unsigned int reply;
    int rc;

    if (iperf_dtls_ctx_init(test, /*server_side=*/0) < 0)
        return -1;

    if ((s = netdial(test->settings->domain, Pudp,
                     test->bind_address, test->bind_dev,
                     test->bind_port, test->server_hostname,
                     test->server_port, -1)) < 0) {
        i_errno = IESTREAMCONNECT;
        return -1;
    }

    bio = BIO_new_dgram(s, BIO_NOCLOSE);
    if (!bio) {
        dtls_report_error("BIO_new_dgram");
        close(s);
        i_errno = IESTREAMCONNECT;
        return -1;
    }

    if (getpeername(s, (struct sockaddr *) &peer, &peerlen) == 0) {
        (void) BIO_ctrl(bio, BIO_CTRL_DGRAM_SET_CONNECTED, 0, &peer);
    }

    ssl = SSL_new((SSL_CTX *) test->dtls_ctx);
    if (!ssl) {
        dtls_report_error("SSL_new");
        BIO_free(bio);
        close(s);
        i_errno = IESTREAMCONNECT;
        return -1;
    }
    SSL_set_bio(ssl, bio, bio);

    /* Bound the handshake. */
    tv.tv_sec = 30;
    tv.tv_usec = 0;
    (void) setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    {
        int crc = SSL_connect(ssl);
        if (crc <= 0) {
            dtls_report_ssl_error("SSL_connect", ssl, crc);
            SSL_free(ssl);
            close(s);
            i_errno = IEDTLSHANDSHAKE;
            return -1;
        }
    }

    /* Mirror the UDP_CONNECT_REPLY handshake (now wrapped in DTLS). */
    rc = SSL_read(ssl, &reply, sizeof(reply));
    if (rc <= 0 ||
        (reply != UDP_CONNECT_REPLY && reply != LEGACY_UDP_CONNECT_REPLY)) {
        dtls_report_error("SSL_read(reply)");
        SSL_free(ssl);
        close(s);
        i_errno = IESTREAMREAD;
        return -1;
    }

    /* Give the subsequent data-path SSL_read a generous default timeout. */
    tv.tv_sec = 30;
    tv.tv_usec = 0;
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    test->dtls_pending_ssl = ssl;
    return s;
}

/*
 * iperf_dtls_send -- write one UDP-framed datagram through the SSL.
 * Matches the non-GSO branch of iperf_udp_send.
 */
int
iperf_dtls_send(struct iperf_stream *sp)
{
    int r;
    int size = sp->settings->blksize;
    struct iperf_time before;
    SSL *ssl = (SSL *) sp->ssl;

    if (!ssl) {
        i_errno = IEDTLSWRITE;
        return -1;
    }

    iperf_time_now(&before);
    ++sp->packet_count;

    if (sp->test->udp_counters_64bit) {
        uint32_t sec, usec;
        uint64_t pcount;
        sec = htonl(before.secs);
        usec = htonl(before.usecs);
        pcount = htobe64(sp->packet_count);
        memcpy(sp->buffer + 0, &sec, sizeof(sec));
        memcpy(sp->buffer + 4, &usec, sizeof(usec));
        memcpy(sp->buffer + 8, &pcount, sizeof(pcount));
    } else {
        uint32_t sec, usec, pcount;
        sec = htonl(before.secs);
        usec = htonl(before.usecs);
        pcount = htonl((uint32_t) sp->packet_count);
        memcpy(sp->buffer + 0, &sec, sizeof(sec));
        memcpy(sp->buffer + 4, &usec, sizeof(usec));
        memcpy(sp->buffer + 8, &pcount, sizeof(pcount));
    }

    r = SSL_write(ssl, sp->buffer, size);
    if (r <= 0) {
        int err = SSL_get_error(ssl, r);
        if (err == SSL_ERROR_WANT_READ || err == SSL_ERROR_WANT_WRITE) {
            --sp->packet_count;
            return NET_SOFTERROR;
        }
        --sp->packet_count;
        if (sp->test->debug_level >= DEBUG_LEVEL_INFO)
            dtls_report_error("SSL_write");
        return -1;
    }

    sp->result->bytes_sent += r;
    sp->result->bytes_sent_this_interval += r;

    if (sp->test->debug_level >= DEBUG_LEVEL_DEBUG)
        printf("dtls sent %d bytes, total %" PRIu64 "\n", r,
               (uint64_t) sp->result->bytes_sent);

    return r;
}

/*
 * iperf_dtls_recv -- receive one UDP-framed datagram through the SSL.
 * Mirrors the non-GRO branch of iperf_udp_recv (jitter/loss accounting).
 */
int
iperf_dtls_recv(struct iperf_stream *sp)
{
    uint32_t sec, usec;
    uint64_t pcount;
    int r;
    int size = sp->settings->blksize;
    int first_packet = 0;
    double transit, d;
    struct iperf_time sent_time, arrival_time, temp_time;
    struct iperf_test *test = sp->test;
    SSL *ssl = (SSL *) sp->ssl;

    if (!ssl) {
        i_errno = IEDTLSREAD;
        return -1;
    }

    r = SSL_read(ssl, sp->buffer, size);
    if (r <= 0) {
        int err = SSL_get_error(ssl, r);
        if (err == SSL_ERROR_WANT_READ || err == SSL_ERROR_WANT_WRITE)
            return 0;
        if (sp->test->debug_level >= DEBUG_LEVEL_INFO)
            dtls_report_error("SSL_read");
        return r;
    }

    if (test->state != TEST_RUNNING) {
        if (test->debug_level >= DEBUG_LEVEL_INFO)
            printf("Late DTLS receive, state = %d\n", test->state);
        return r;
    }

    if (sp->result->bytes_received == 0)
        first_packet = 1;

    sp->result->bytes_received += r;
    sp->result->bytes_received_this_interval += r;

    if (test->udp_counters_64bit) {
        memcpy(&sec, sp->buffer + 0, sizeof(sec));
        memcpy(&usec, sp->buffer + 4, sizeof(usec));
        memcpy(&pcount, sp->buffer + 8, sizeof(pcount));
        sec = ntohl(sec);
        usec = ntohl(usec);
        pcount = be64toh(pcount);
    } else {
        uint32_t pc;
        memcpy(&sec, sp->buffer + 0, sizeof(sec));
        memcpy(&usec, sp->buffer + 4, sizeof(usec));
        memcpy(&pc, sp->buffer + 8, sizeof(pc));
        sec = ntohl(sec);
        usec = ntohl(usec);
        pcount = ntohl(pc);
    }
    sent_time.secs = sec;
    sent_time.usecs = usec;

    if (pcount >= sp->packet_count + 1) {
        if (pcount > sp->packet_count + 1)
            sp->cnt_error += (pcount - 1) - sp->packet_count;
        sp->packet_count = pcount;
    } else {
        sp->outoforder_packets++;
        if (sp->cnt_error > 0)
            sp->cnt_error--;
    }

    iperf_time_now(&arrival_time);
    iperf_time_diff(&arrival_time, &sent_time, &temp_time);
    transit = iperf_time_in_secs(&temp_time);
    if (first_packet)
        sp->prev_transit = transit;
    d = transit - sp->prev_transit;
    if (d < 0)
        d = -d;
    sp->prev_transit = transit;
    sp->jitter += (d - sp->jitter) / 16.0;

    return r;
}

int
iperf_dtls_init(struct iperf_test *test)
{
    (void) test;
    return 0;
}

#endif /* HAVE_DTLS */
