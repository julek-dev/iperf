/*
 * iperf_dtls.h -- DTLS 1.2 data-plane protocol handlers for iperf.
 *
 * Written entirely against the OpenSSL API.  When iperf is configured
 * with --with-wolfssl, the build system routes <openssl/...> to
 * wolfSSL's compatibility shims and links -lwolfssl; no wolfSSL
 * identifiers are used anywhere in this file or its .c companion.
 *
 * This file is distributed under a BSD-style license, see LICENSE.
 */
#ifndef __IPERF_DTLS_H
#define __IPERF_DTLS_H

#include "iperf.h"

#if defined(HAVE_DTLS)

/* Protocol handler entry points (struct protocol in iperf.h). */
int iperf_dtls_accept(struct iperf_test *);
int iperf_dtls_listen(struct iperf_test *);
int iperf_dtls_connect(struct iperf_test *);
int iperf_dtls_send(struct iperf_stream *);
int iperf_dtls_recv(struct iperf_stream *);
int iperf_dtls_init(struct iperf_test *);

/* Lifecycle helpers called from iperf_api.c. */
int  iperf_dtls_ctx_init(struct iperf_test *test, int server_side);
void iperf_dtls_ctx_free(struct iperf_test *test);
void iperf_dtls_stream_free(struct iperf_stream *sp);

#endif /* HAVE_DTLS */

#endif /* __IPERF_DTLS_H */
