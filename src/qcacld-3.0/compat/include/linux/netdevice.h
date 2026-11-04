#ifndef _QCA_MAINLINE_NETDEVICE_COMPAT_H
#define _QCA_MAINLINE_NETDEVICE_COMPAT_H
#include_next <linux/netdevice.h>
#ifndef init_dummy_netdev
static inline int qca_init_dummy_netdev(struct net_device *dev)
{
	memset(dev, 0, sizeof(*dev));
	dev->reg_state = NETREG_DUMMY;
	set_bit(__LINK_STATE_PRESENT, &dev->state);
	set_bit(__LINK_STATE_START, &dev->state);
	return 0;
}
#define init_dummy_netdev qca_init_dummy_netdev
#endif
#endif
