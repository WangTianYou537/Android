/* Bionic shims for GNU bash on Android. */
#include <stddef.h>
#include <wchar.h>
#include <string.h>

/* ------------------------------------------------------------------ */
/* mblen: not exported from Android libc.so                           */
/* ------------------------------------------------------------------ */

int mblen(const char *s, size_t n)
{
  if (s == NULL)
    return 0; /* always initial shift state */
  if (n == 0)
    return -1;
  mbstate_t st;
  memset(&st, 0, sizeof(st));
  size_t r = mbrlen(s, n, &st);
  if (r == (size_t)-1 || r == (size_t)-2)
    return -1;
  return (int)r;
}

/* ------------------------------------------------------------------ */
/* getgrent / getpwent family (API < 26)                              */
/* Weak stubs: empty enumeration. Path/cmd Tab completion unaffected. */
/* ------------------------------------------------------------------ */

#if defined(__ANDROID__) && defined(__ANDROID_API__) && (__ANDROID_API__ < 26)

struct group;
struct passwd;

__attribute__((weak)) void setgrent(void) {}
__attribute__((weak)) void endgrent(void) {}
__attribute__((weak)) struct group *getgrent(void) { return NULL; }

__attribute__((weak)) void setpwent(void) {}
__attribute__((weak)) void endpwent(void) {}
__attribute__((weak)) struct passwd *getpwent(void) { return NULL; }

#endif /* __ANDROID_API__ < 26 */