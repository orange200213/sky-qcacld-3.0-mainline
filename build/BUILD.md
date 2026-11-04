# Build guide — sky (SM4450) + WCN6750 adrastea on Linux 7.3

Covers the **whole chain**: kernel → DTB → three kernel modules
(`wlan_firmware_service`, `icnss2`, `wlan`) → boot-image packaging.
Everything is cross-compiled on an x86_64 host for `arm64`.

> Chinese version: [`BUILD.zh.md`](BUILD.zh.md)

---

## 1. Environment (versions actually used)

| Item | Value |
|---|---|
| Kernel source | Linux **7.3.0**, `git describe` = `78458d4ee-dirty` (local tree) |
| Target vermagic | `7.3.0-g78458d4eea4e-dirty SMP preempt aarch64` |
| Cross compiler | `aarch64-linux-gnu-gcc` **13.3.0** (Ubuntu 13.3.0-6ubuntu2~24.04.1) |
| binutils | GNU ld **2.42** |
| Host | x86_64 Ubuntu 24.04 |

> The vermagic must match the target kernel **exactly**, otherwise `insmod` fails with
> `invalid module format`. Any kernel change requires rebuilding all three modules.

Relevant kernel config fragment: [`kernel-config-sky-7.3.fragment`](kernel-config-sky-7.3.fragment).
Highlights: `CONFIG_MODULES=y`, `CONFIG_CFG80211=y`, `CONFIG_QRTR`, `CONFIG_QMI_HELPERS`
(`linux/soc/qcom/qmi.h`), `CONFIG_REMOTEPROC` + `QCOM_Q6V5_PAS` (wpss),
`CONFIG_ARM_SMMU`, `CONFIG_MODULE_SIG=n`, `CONFIG_MODVERSIONS=n`
(with modversions the `Module.symvers` files must match pairwise).

## 2. Source layout

Everything needed is in this repository; `KERNEL_SRC` points at an external Linux 7.3 tree:

```
src/icnss2/                 ← build entry point: port.mk
  drivers/soc/qcom/icnss2/  ← icnss2 sources (main.c/qmi.c/power.c/...)
  wlan_firmware_service_v01.{c,h}   ← WLFW QMI service definitions (exports wlfw_*_ei)
  cnss_utils.c / cnss_plat_ipc_*    ← built by the "dependencies" target
src/qcacld-3.0/             ← qcacld (contains symlink cmn → ../qca-wifi-host-cmn)
src/qca-wifi-host-cmn/      ← shared components (HIF/CE/QDF)
```

⚠️ The default `KERNEL_SRC` inside `port.mk` points at the original developer's tree —
**always override it**: `KERNEL_SRC=/path/to/linux-7.3`.

## 3. Three-step build (order matters)

```sh
export KERNEL_SRC=/path/to/linux-7.3

# (1) dependency modules: cnss_utils.ko etc.; produces src/icnss2/Module.symvers
make -C src/icnss2 -f port.mk KERNEL_SRC=$KERNEL_SRC dependencies

# (2) platform module: icnss2.ko (consumes the Module.symvers from step 1)
make -C src/icnss2 -f port.mk KERNEL_SRC=$KERNEL_SRC platform

# (3) main driver: wlan.ko (consumes icnss2's Module.symvers; re-runs "platform" first)
make -C src/icnss2 -f port.mk KERNEL_SRC=$KERNEL_SRC \
     WLAN_DIR=$PWD/src/qcacld-3.0 wlan
```

One-shot: `KERNEL_SRC=/path/to/linux-7.3 ./build/build.sh all`

### Key compile switches (baked into `port.mk`)

```make
WLAN_CONFIG := CONFIG_ICNSS2=y CONFIG_QMI_SUPPORT=y CONFIG_PLD_SNOC_ICNSS_FLAG=y \
               CONFIG_WIFI_3_0_ADRASTEA=y CONFIG_ADRASTEA_SHADOW_REGISTERS=y \
               CONFIG_ADRASTEA_RRI_ON_DDR=y CONFIG_HIF_SNOC=y
# extra flags for the "platform" target
KCFLAGS='-DCONFIG_ICNSS2_QMI -DCONFIG_ICNSS2_ADRASTEA_MAINLINE'
```

* `CONFIG_ICNSS2_QMI=y` is **mandatory**; without it the stock zero-return stubs are used
  and every QMI call silently "succeeds".
* `CONFIG_ADRASTEA_SHADOW_REGISTERS=y` — adrastea drives CE write indices through the
  SR_APSS shadow slots; this is what makes the platform work at all
  (measured on hardware: `ADDRESS_VALID = 0xf860b9`).
* `CONFIG_HIF_SNOC=y` — SNOC bus (not PCIe).

## 4. Artifacts and verification

| Artifact | Path | Size (measured) |
|---|---|---|
| `wlan_firmware_service.ko` | `src/icnss2/` | 134,920 B |
| `cnss_utils.ko` | `src/icnss2/` | 79,840 B |
| `icnss2.ko` | `src/icnss2/drivers/soc/qcom/icnss2/` | 809,992 B |
| `wlan.ko` | `src/qcacld-3.0/` | 62,484,880 B |

```sh
for f in src/icnss2/drivers/soc/qcom/icnss2/icnss2.ko src/qcacld-3.0/wlan.ko; do
  strings $f | grep -m1 vermagic=
done
ssh root@<device> 'uname -r'      # must match the vermagic prefix
```
The `.ko` files in `modules/` are **known-good snapshots** (md5 in `versions.txt`).

## 5. Device tree (DTB)

`dts/sm4450-xiaomi-sky.dts` must be compiled with **cpp preprocessing followed by dtc**
(plain `dtc` fails on `#include <dt-bindings/...>`):

```sh
K=$KERNEL_SRC
cpp -nostdinc -I $K/include -I $K/arch/arm64/boot/dts/qcom -I dts \
    -undef -x assembler-with-cpp dts/sm4450-xiaomi-sky.dts -o /tmp/sky.pre.dts
dtc -I dts -O dtb -o /tmp/sky.dtb /tmp/sky.pre.dts
```
⚠️ Do **not** regenerate the DTS with the upstream `tools/mksky_dts.py` (it overwrites
the hand-edited file).

## 6. Boot image packaging

Use the shim's official packer (fixed-offset overwriting causes
`payload overlaps the kernel or DTB` / `HALT payload did not start Linux`):

```sh
./shim/make-m1.sh $KERNEL_SRC/arch/arm64/boot/Image /tmp/sky.dtb
# output: out/sky-shim-boot-v4.img — the correct size is 120,086,528 B
```
Flash: `fastboot flash boot_a out/sky-shim-boot-v4.img`, or on the device
`dd if=img of=/dev/sde13 bs=4096` (boot_a).

## 7. Deploying to the device

```sh
# Firmware (mandatory, and md5-verify it: a flaky USB link produces
# "correct size, all-zero content")
/lib/firmware/qcom/sm4450/xiaomi-sky/wpss.*            ← from ROM NON-HLOS.bin
/lib/firmware/adrastea/{regdb.bin,bdwlant_cn.bin,bdwlant_jp.bin}
/lib/firmware/wlan/qca_cld/WCNSS_qcom_cfg.ini          ← path-sensitive
# optional, also verified to work: /vendor/firmware/wlan/qca_cld/ copies

# Load (CONFIG_MODULE_UNLOAD=n ⇒ one insmod per boot)
insmod wlan_firmware_service.ko
insmod icnss2.ko        # ~8 s later: "WLAN FW is ready: 0x487"
insmod wlan.ko          # wlan0 appears
ip link set wlan0 up && iw dev wlan0 scan
```

## 8. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `icnss2: Fail to get IRQ-0` | used `platform_get_resource(IORESOURCE_IRQ)`; the platform device has no resource table — use `platform_get_irq()` |
| probe returns `-1`, no logs at all | `cfg_parse("wlan/qca_cld/WCNSS_qcom_cfg.ini")` failed → ini missing from `/lib/firmware/wlan/qca_cld/` |
| oops in `netif_napi_add_weight_locked` | `qca_napi_info.netdev` uninitialised → `INIT_LIST_HEAD(&dev->napi_list)` |
| `invalid module format` | vermagic mismatch or corrupted transfer (check md5) |
| `Unknown symbol wlfw_*_ei` | `wlan_firmware_service.ko` not loaded first (it exports 93 symbols) |
| BDF download `result=1, err=1` | firmware file content is empty (USB corruption) — verify md5 on both sides |
| device drops into fastboot | `fastboot flash boot_a out/sky-shim-boot-v4.img` + `fastboot reboot` |

## 9. Debug instrumentation (added while chasing the bugs; strip for production)

* `patch/wlan_hdd_driver_ops.c.patch` — `sky-dbg:` prints in `hdd_soc_probe()`
  (including `osif_psoc_sync_create_and_trans`) and in `__hdd_soc_probe()` after each
  of the five steps plus `hdd_psoc_create_vdevs()`.
* `patch/wlan_hdd_main.c.patch` — `sky-dbg2:` prints for the eight sub-steps of
  `hdd_context_create()`.
* `patch/hif_napi.c.patch` — the NAPI `net_device` initialisation fix.

Three further icnss2-side changes have no `.bak` file; they are described here:
IRQ acquisition in `main.c`, first-segment field dump + `ath11k_bdf_chunk` in `qmi.c`,
and promoting `icnss_pr_dbg` to `printk(KERN_INFO)` in `debug.h`.

## 10. Known limitations

* No association (WPA2/WPA3), DHCP, throughput or SSR-recovery validation yet.
* `wlan.ko` is 62 MB including debug info; run `strip --strip-debug` for production.
* Only validated on this device (Redmi 12 5G / sky, JP firmware 2024-09).
