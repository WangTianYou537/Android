/* Android Bionic stubs for OpenSSH. */
#include <pwd.h>
#include <stddef.h>

#if defined(__ANDROID__) && defined(__ANDROID_API__) && (__ANDROID_API__ < 26)
/* Passwd DB enumeration only declared for API >= 26. */
struct passwd *getpwent(void) { return NULL; }
void setpwent(void) {}
void endpwent(void) {}
#endif
