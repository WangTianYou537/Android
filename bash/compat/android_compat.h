/* Android Bionic shims for bash cross-build (API < 26 safe). */
#ifndef BASH_ANDROID_COMPAT_H
#define BASH_ANDROID_COMPAT_H

#include <stddef.h>

/* mblen is not exported from Android libc.so on some API levels. */
int mblen(const char *s, size_t n);

/*
 * getgrent/getpwent family: only declared in Bionic headers for API >= 26.
 * bash 5.3 bashline.c may call them even when HAVE_GETGRENT is unset.
 * Provide declarations for the compiler; stubs live in android_compat.c.
 */
#if defined(__ANDROID__) && defined(__ANDROID_API__) && (__ANDROID_API__ < 26)

struct group;
struct passwd;

void setgrent(void);
void endgrent(void);
struct group *getgrent(void);

void setpwent(void);
void endpwent(void);
struct passwd *getpwent(void);

#endif /* __ANDROID_API__ < 26 */

#endif /* BASH_ANDROID_COMPAT_H */