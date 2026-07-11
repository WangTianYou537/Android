/*
 * Android OpenJDK build: iconv declarations for minSdk < 28.
 *
 * Bionic only declares iconv_* when __ANDROID_API__ >= 28. The Android
 * patch ships libtinyiconv (iconv.cpp) with a software implementation, but
 * EncodingSupport_md.c / utf_util.c still #include <iconv.h> and need
 * prototypes. Prefer this header via -I.../libtinyiconv (EXTRA_HEADER_DIRS).
 */
#ifndef ANDROID_OPENJDK_TINY_ICONV_H
#define ANDROID_OPENJDK_TINY_ICONV_H

#include <stddef.h>
#include <sys/cdefs.h>

__BEGIN_DECLS

/* Match Bionic's opaque converter type. */
struct __iconv_t;
typedef struct __iconv_t *iconv_t;

iconv_t iconv_open(const char *dst_encoding, const char *src_encoding);
size_t iconv(iconv_t converter,
             char **src_buf, size_t *src_bytes_left,
             char **dst_buf, size_t *dst_bytes_left);
int iconv_close(iconv_t converter);

__END_DECLS

#endif /* ANDROID_OPENJDK_TINY_ICONV_H */
