/* Android Bionic shims for GNU coreutils (official GNU sources). */
#include <sys/utsname.h>

/* Bionic has no gethostid(3). Provide a stable-ish nodename hash. */
long gethostid(void)
{
  struct utsname u;
  unsigned long h = 0;
  if (uname(&u) == 0) {
    const unsigned char *p = (const unsigned char *)u.nodename;
    while (*p)
      h = h * 131u + *p++;
  }
  return (long)(h & 0xffffffffUL);
}
