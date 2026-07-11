/* Bionic shims: mblen is not exported from Android libc.so. */
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
