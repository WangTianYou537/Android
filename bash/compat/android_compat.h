/* Android Bionic shims for bash cross-build (API < 26 safe). */
#ifndef BASH_ANDROID_COMPAT_H
#define BASH_ANDROID_COMPAT_H

#include <stddef.h>

int mblen(const char *s, size_t n);

/* strchrnul exists in Bionic (API >= 24) but some TUs miss the declaration. */
char *strchrnul(const char *s, int c);

#if defined(__ANDROID__) && defined(__ANDROID_API__) && (__ANDROID_API__ < 26)

struct group;
struct passwd;

void setgrent(void);
void endgrent(void);
struct group *getgrent(void);

void setpwent(void);
void endpwent(void);
struct passwd *getpwent(void);

#endif

#endif
