#ifndef _QCA_MAINLINE_HRTIMER_COMPAT_H
#define _QCA_MAINLINE_HRTIMER_COMPAT_H
#include_next <linux/hrtimer.h>
#ifndef hrtimer_init
#define hrtimer_init(timer, clock, mode) \
	hrtimer_setup((timer), hrtimer_dummy_timeout, (clock), (mode))
#endif
#include <linux/hrtimer_bases.h>
#endif
