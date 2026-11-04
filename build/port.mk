# Source-only cross-build of the pinned MiCode platform dependency stack.
PORT_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
KERNEL_SRC ?= $(abspath $(PORT_ROOT)/../../../sky-mainline/kernel/linux-7.3)
ARCH ?= arm64
CROSS_COMPILE ?= aarch64-linux-gnu-
ICNSS_DIR := $(PORT_ROOT)/drivers/soc/qcom/icnss2
WLAN_DIR ?= $(abspath $(PORT_ROOT)/../micode-sky-t-oss/qcacld-3.0)
PORT_INCLUDES := -I$(PORT_ROOT)/include -I$(PORT_ROOT)
WLAN_CONFIG := CONFIG_ICNSS2=y CONFIG_QMI_SUPPORT=y CONFIG_PLD_SNOC_ICNSS_FLAG=y CONFIG_WIFI_3_0_ADRASTEA=y CONFIG_ADRASTEA_SHADOW_REGISTERS=y CONFIG_ADRASTEA_RRI_ON_DDR=y CONFIG_HIF_SNOC=y

.PHONY: dependencies platform wlan
dependencies:
	$(MAKE) -C $(KERNEL_SRC) M=$(PORT_ROOT) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) CONFIG_CNSS_QMI_SVC=m CONFIG_CNSS_UTILS=m KCFLAGS='$(PORT_INCLUDES)' modules

# Deliberately builds real QMI, never the stock !CONFIG_ICNSS2_QMI zero-return stubs.
# Adrastea uses mainline's single WPSS SSR notifier; early hook timing is not identical.
platform:
	$(MAKE) -C $(KERNEL_SRC) M=$(ICNSS_DIR) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) CONFIG_ICNSS2=m CONFIG_ICNSS2_QMI=y KCFLAGS='-DCONFIG_ICNSS2_QMI -DCONFIG_ICNSS2_ADRASTEA_MAINLINE $(PORT_INCLUDES)' KBUILD_EXTRA_SYMBOLS=$(PORT_ROOT)/Module.symvers modules

wlan: platform
	$(MAKE) -C $(WLAN_DIR) KERNEL_SRC=$(KERNEL_SRC) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) KBUILD_EXTRA='$(WLAN_CONFIG)' KBUILD_EXTRA_SYMBOLS=$(ICNSS_DIR)/Module.symvers all
