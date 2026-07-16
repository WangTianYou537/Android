#include <stddef.h>
#include <wchar.h>
#include <string.h>

int mblen(const char *s, size_t n)
{
  if (s == NULL)
    return 0;
  if (n == 0)
    return -1;
  mbstate_t st;
  memset(&st, 0, sizeof(st));
  size_t r = mbrlen(s, n, &st);
  if (r == (size_t)-1 || r == (size_t)-2)
    return -1;
  return (int)r;
}

#if defined(__ANDROID__) && defined(__ANDROID_API__) && (__ANDROID_API__ < 26)

struct group;
struct passwd;

__attribute__((weak)) void setgrent(void) {}
__attribute__((weak)) void endgrent(void) {}
__attribute__((weak)) struct group *getgrent(void) { return NULL; }

__attribute__((weak)) void setpwent(void) {}
__attribute__((weak)) void endpwent(void) {}
__attribute__((weak)) struct passwd *getpwent(void) { return NULL; }

#endif
