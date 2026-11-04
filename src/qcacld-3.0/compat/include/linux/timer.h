#ifndef _QCA_MAINLINE_TIMER_COMPAT_H
#define _QCA_MAINLINE_TIMER_COMPAT_H
#include_next <linux/timer.h>
#include <linux/container_of.h>
#ifndef from_timer
#define from_timer(var, callback_timer, timer_field) \
	container_of(callback_timer, typeof(*var), timer_field)
#endif
#ifndef del_timer
#define del_timer(timer) timer_delete(timer)
#endif
#ifndef del_timer_sync
#define del_timer_sync(timer) timer_delete_sync(timer)
#endif
#ifndef destroy_timer_on_stack
#define destroy_timer_on_stack(timer) do { } while (0)
#endif
#endif
