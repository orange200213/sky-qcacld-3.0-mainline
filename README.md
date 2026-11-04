# sky-qcacld-3.0-mainline

Mainlining **qcacld-3.0** on **Linux 7.3** for the Xiaomi Redmi 12 5G
(`sky` / SM4450 "ravelin") with the **WCN6750 "adrastea"** SNOC WLAN chip.

This repository holds the working sources, built kernel modules, firmware, device tree,
patches and the full investigation log.

> Chinese version: [`README.zh.md`](README.zh.md) · **Install guide: [`INSTALL.md`](INSTALL.md)** · Build guide: [`build/BUILD.md`](build/BUILD.md)

---

## 1. Why not ath11k (what makes this device special)

The project started with mainline `ath11k` (upstream does support
`ath11k_hw_wcn6750` / `qcom,wcn6750-wifi`). Measurements on real hardware showed that
**the mainline ath11k model cannot work on this device**, because of how the
APSS is allowed to reach WCSS registers:

| Finding (measured on hardware) | Evidence |
|---|---|
| Inside the 8 MiB `membase` window (`0x22800000`) **only `0x20000..0x52000` (SR_APSS) is accessible** | `membase+0x240000` (CE0), `+0x24C000` (CE wrapper), `+0x2xxxxx` are all DEAD; a 123-probe scan of `0x22850000..0x23000000` returned 0 live pages |
| The only host-writable register path is the **SR_APSS shadow-slot window** | After `WLAN_CFG` carries the `shadow_reg`(v1) table with 12 entries, `ADDRESS_VALID = 0xf860b9`; writes to `SHADOW_VALUE[n]` are forwarded (`DIRTY` consumed, `INVALID_ADDR_ACCESS = 0`) |
| Shadow slots cover **CE write indices only** (offsets `0x3C` / `0x40`) | Slot map: `src CE 0/3/4/5/7 → slot 0/3/4/5/7`, `dst CE 1/2/7/8/9/10/11 → slot 13/14/19/20/21/22/23` |
| The host **cannot** program CE ring base/size, nor touch UMAC/WBM/REO/TCL | Zero-MMIO experiment: with all reads/writes filtered out, bring-up only reaches HTC and then times out |
| The firmware does **not** create the CE rings for the host | Same experiment; the host never even kicks a write index before HTC-ready arrives |

⇒ The mainline ath11k model ("host programs CE/DP rings") is **impossible** on this chip.
The vendor solution is **qcacld-3.0 `adrastea` profile + icnss2**, where the datapath is
firmware-managed. This project therefore **mainlines qcacld-3.0 / icnss2 onto Linux 7.3**.

> The complete ath11k-era investigation (register scans, shadow-register mechanism,
> QMI sequence analysis) lives in `docs/FINDINGS-session6..9-*.md`
> and `docs/HANDOFF-snoc-mainline.md`.

---

## 2. Current status

Running on mainline 7.3:

```
icnss2: Platform driver probed successfully
fw_version: 0x3431fb72 (2024-09-03, WLAN.HL.3.4.3-00346-QCAHLSWMTPLZ-1.31602.10)
REGDB / BDF download over QMI WLFW: OK
cal report → icnss2: WLAN FW is ready: 0x487
wlan.ko loads → wlan0 (managed) appears, MAC 00:0a:f5:a0:f6:c7
iw dev wlan0 scan → lists neighbouring APs
```

Three real bugs were found and fixed (details in
`docs/FINDINGS-qcacld-device-test-2026-11-04.md` §21):

1. **icnss2 IRQ acquisition** — `platform_get_resource(pdev, IORESOURCE_IRQ, i)` fails because
   the platform device has no resource table on this platform; switched to
   `platform_get_irq(pdev, i)` (which falls back to DT parsing).
2. **qcacld `cfg_parse` failure** — `WLAN_INI_FILE` is the relative path
   `wlan/qca_cld/WCNSS_qcom_cfg.ini`; the ini must be present at
   `/lib/firmware/wlan/qca_cld/` (and `/vendor/firmware/wlan/qca_cld/`).
3. **NAPI oops** — the embedded `net_device` inside `struct qca_napi_info` was never
   initialised, while Linux 7.3's `netif_napi_add_weight_locked()` touches `dev->napi_list`.
   `init_dummy_netdev()` is not exported, so it is initialised manually.

Patches: `patch/`. Full log: `docs/`.

---

## 3. Repository layout

```
README.md                    this file (English, default)
README.zh.md                 Chinese version
docs/                        full handoff + experiment log (ath11k era and qcacld era)
dts/                         sm4450-xiaomi-sky.dts (icnss node + touch fixes) + attic/
src/icnss2/                  icnss2 platform driver, wlan_firmware_service_v01.{c,h}, port.mk
src/qcacld-3.0/              qcacld-3.0 sources (build artefacts stripped)
src/qca-wifi-host-cmn/       shared components (HIF/CE/QDF)
build/                       BUILD.md, port.mk, build.sh, kernel config fragment, versions.txt
modules/                     built modules: wlan.ko, icnss2.ko, wlan_firmware_service.ko, cnss_utils.ko
firmware/                    stock (JP) adrastea firmware + regdb/BDF, extracted from NON-HLOS.bin
patch/                       source changes made for the mainline port (unified diffs)
```

## 4. Build

See **[`build/BUILD.md`](build/BUILD.md)** for the full guide (versions, three-step build,
DTB, boot-image packaging, deployment, troubleshooting table).
One-shot script: `KERNEL_SRC=/path/to/linux-7.3 build/build.sh all`

```sh
make -C src/icnss2 -f port.mk KERNEL_SRC=$KERNEL_SRC dependencies   # cnss_utils etc.
make -C src/icnss2 -f port.mk KERNEL_SRC=$KERNEL_SRC platform       # → icnss2.ko
make -C src/icnss2 -f port.mk KERNEL_SRC=$KERNEL_SRC \
     WLAN_DIR=$PWD/src/qcacld-3.0 wlan                              # → wlan.ko
```

Key switches (fixed in `port.mk`):
`CONFIG_ICNSS2=m CONFIG_ICNSS2_QMI=y CONFIG_PLD_SNOC_ICNSS_FLAG=y CONFIG_WIFI_3_0_ADRASTEA=y
CONFIG_ADRASTEA_SHADOW_REGISTERS=y CONFIG_ADRASTEA_RRI_ON_DDR=y CONFIG_HIF_SNOC=y`

## 5. Loading on the device (see [`INSTALL.md`](INSTALL.md) for the full step-by-step guide) (one `insmod` per boot: `CONFIG_MODULE_UNLOAD=n`)

```sh
# Required files
#   /lib/firmware/qcom/sm4450/xiaomi-sky/wpss.*        remote-processor firmware
#   /lib/firmware/adrastea/{regdb.bin,bdwlant_*.bin}   BDF/regdb downloaded over QMI
#   /lib/firmware/wlan/qca_cld/WCNSS_qcom_cfg.ini      qcacld ini (path-sensitive)

insmod wlan_firmware_service.ko
insmod icnss2.ko            # wait ~8 s: expect "WLAN FW is ready: 0x487"
insmod wlan.ko              # expect wlan0 to appear
ip link set wlan0 up && iw dev wlan0 scan
```

## 6. Known limitations / TODO

* No association (WPA2/WPA3), DHCP or throughput testing yet.
* cfg80211 specifics not verified: ROC cookie, mgmt TX status, change_beacon,
  control port, key install/reconnect/delete.
* SSR (WPSS restart) recovery path not verified.
* Modules are bound to the exact kernel (`vermagic 7.3.0-g78458d4eea4e-dirty`);
  rebuilding is required for any other kernel.
* The device tree must provide the `qcom,icnss` node (see `dts/`), with the stock
  12 MiB MSA reservation.
