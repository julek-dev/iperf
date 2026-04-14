# ===========================================================================
#     AX_CHECK_WOLFSSL
# ===========================================================================
#
# SYNOPSIS
#
#   AX_CHECK_WOLFSSL([action-if-found[, action-if-not-found]])
#
# DESCRIPTION
#
#   Locate a wolfSSL installation and set flags such that iperf's source
#   code, which is written against the OpenSSL API, can be built against
#   wolfSSL's OpenSSL compatibility layer.
#
#   Honors --with-wolfssl[=DIR]. If pkg-config knows about wolfssl.pc,
#   that is preferred. Otherwise DIR (or the default /opt/wolfssl,
#   /usr/local) is searched for include/wolfssl/options.h.
#
#   Sets:
#     WOLFSSL_INCLUDES  e.g. "-I<prefix>/include -include wolfssl/options.h"
#     WOLFSSL_LDFLAGS   e.g. "-L<prefix>/lib"
#     WOLFSSL_LIBS      "-lwolfssl"
#
#   The -include wolfssl/options.h is critical: it forces wolfSSL's
#   feature-configuration header to be processed before any other
#   translation unit, which in turn activates OPENSSL_EXTRA and routes
#   all <openssl/*.h> includes through wolfSSL's compatibility shims.
#   This keeps iperf's source 100% OpenSSL-API based.

AC_DEFUN([AX_CHECK_WOLFSSL], [
    wolfssl_found=false
    WOLFSSL_INCLUDES=
    WOLFSSL_LDFLAGS=
    WOLFSSL_LIBS=

    AS_CASE(["$with_wolfssl"],
        ["" | y | ye | yes],
            [wolfssl_search_dirs="/opt/wolfssl /usr/local /usr"],
        [no],
            [wolfssl_search_dirs=""],
        [wolfssl_search_dirs="$with_wolfssl"])

    # Prefer pkg-config if wolfssl.pc is installed (and user didn't
    # pin us to a specific prefix).
    AS_IF([test "x$with_wolfssl" = "xyes" -o "x$with_wolfssl" = "x"], [
        AC_CHECK_TOOL([PKG_CONFIG], [pkg-config])
        AS_IF([test x"$PKG_CONFIG" != x""], [
            AS_IF([$PKG_CONFIG --exists wolfssl 2>/dev/null], [
                WOLFSSL_LDFLAGS=`$PKG_CONFIG wolfssl --libs-only-L 2>/dev/null`
                WOLFSSL_LIBS=`$PKG_CONFIG wolfssl --libs-only-l 2>/dev/null`
                WOLFSSL_INCLUDES=`$PKG_CONFIG wolfssl --cflags-only-I 2>/dev/null`
                WOLFSSL_INCLUDES="$WOLFSSL_INCLUDES -include wolfssl/options.h"
                wolfssl_found=true
            ])
        ])
    ])

    AS_IF([test "x$wolfssl_found" != xtrue && test -n "$wolfssl_search_dirs"], [
        for wdir in $wolfssl_search_dirs; do
            AC_MSG_CHECKING([for $wdir/include/wolfssl/options.h])
            AS_IF([test -f "$wdir/include/wolfssl/options.h"], [
                # -I.../wolfssl is what makes <openssl/ssl.h> resolve to
                # wolfSSL's compatibility shim (wolfssl/openssl/ssl.h).
                WOLFSSL_INCLUDES="-I$wdir/include -I$wdir/include/wolfssl -include wolfssl/options.h"
                WOLFSSL_LDFLAGS="-L$wdir/lib"
                WOLFSSL_LIBS="-lwolfssl"
                wolfssl_found=true
                AC_MSG_RESULT([yes])
                break
            ], [
                AC_MSG_RESULT([no])
            ])
        done
    ])

    AC_MSG_CHECKING([whether compiling and linking against wolfSSL OpenSSL-compat works])
    save_LIBS="$LIBS"
    save_LDFLAGS="$LDFLAGS"
    save_CPPFLAGS="$CPPFLAGS"
    LDFLAGS="$LDFLAGS $WOLFSSL_LDFLAGS"
    LIBS="$WOLFSSL_LIBS $LIBS"
    CPPFLAGS="$WOLFSSL_INCLUDES $CPPFLAGS"
    AC_LINK_IFELSE(
        [AC_LANG_PROGRAM([[#include <openssl/ssl.h>]],
                         [[(void) SSL_CTX_new(DTLS_method());]])],
        [AC_MSG_RESULT([yes]); $1],
        [AC_MSG_RESULT([no]); wolfssl_found=false; $2])
    CPPFLAGS="$save_CPPFLAGS"
    LDFLAGS="$save_LDFLAGS"
    LIBS="$save_LIBS"

    AC_SUBST([WOLFSSL_INCLUDES])
    AC_SUBST([WOLFSSL_LIBS])
    AC_SUBST([WOLFSSL_LDFLAGS])
])
