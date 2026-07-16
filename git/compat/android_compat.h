/* Force-included when building official git for Android. */
#ifndef GIT_ANDROID_COMPAT_H
#define GIT_ANDROID_COMPAT_H

/* Bionic has pthreads but not pthread cancellation. */
#if defined(__ANDROID__)
# ifndef PTHREAD_CANCEL_DISABLE
#  define PTHREAD_CANCEL_DISABLE 0
# endif
# ifndef PTHREAD_CANCEL_ENABLE
#  define PTHREAD_CANCEL_ENABLE 1
# endif
static inline int pthread_setcancelstate(int state, int *oldstate)
{
	(void)state;
	if (oldstate)
		*oldstate = PTHREAD_CANCEL_ENABLE;
	return 0;
}
static inline int pthread_setcanceltype(int type, int *oldtype)
{
	(void)type;
	if (oldtype)
		*oldtype = 0;
	return 0;
}
#endif

#endif
