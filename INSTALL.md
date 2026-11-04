# Installation guide — sky (Redmi 12 5G) WLAN modules on Linux 7.3

Step-by-step installation of the mainlined **qcacld-3.0 + icnss2** WLAN stack on a
Xiaomi Redmi 12 5G (`sky`, SM4450 + WCN6750 "adrastea") running mainline Linux **7.3**.

> Chinese version: [`INSTALL.zh.md`](INSTALL.zh.md)

---

## 0. Requirements (check first)

| Item | Value | How to check |
|---|---|---|
| Device | Xiaomi Redmi 12 5G / `sky` (SM4450, WCN6750 adrastea) | `cat /proc/device-tree/model` |
| Kernel | **exactly** `7.3.0-g78458d4eea4e-dirty` | `uname -r` |
| Module vermagic | `7.3.0-g78458d4eea4e-dirty SMP preempt aarch64` | `strings wlan.ko \| grep vermagic` |
| Kernel config | `CONFIG_MODULE_UNLOAD=n` on this build ⇒ **one load per boot** | — |
| Device tree | must contain the `qcom,icnss` node (12 CE IRQs, MSA 12 MiB) | `ls /proc/device-tree/soc@0 \| grep wifi` |
| Root | SSH/adb root shell | — |

⚠️ **If `uname -r` differs from the vermagic, the modules will not load**
(`invalid module format`). Rebuild from source (`build/BUILD.md`) instead.

## 1. Files to install

Release assets (all md5-verified):

```
wlan.ko                     3adcf546046b5aa2295ecc5f9a63db17   62,484,880 B
icnss2.ko                   e279bc58c257a69dafac3c914b2f34e1      809,992 B
wlan_firmware_service.ko    e468d18624449535676e4fd583fbdc80      134,920 B
cnss_utils.ko               4263db5976a511b66354dc4758a8ab2a       79,840 B

fpga/firmware (adrastea):
wpss.mdt                    ccf4f902e92fd04fc6319671d5933090        4,684 B
wpss.b00 … wpss.b10         (see §4 checksums)
regdb.bin                   8889032e43d7228d6b1ad1e8c33cf73d       19,348 B
bdwlant_jp.bin              e8d5ed7ac1910a65c990640204b27cb8       26,328 B
bdwlant_cn.bin             3ea6e413fe84a33844d0fde2906724bf       26,328 B
WCNSS_qcom_cfg.ini          936d61551e133a65197d5a9b354b7d8e       13,913 B
```

## 2. Target paths on the device

```
/root/wlan_firmware_service.ko
/root/icnss2.ko
/root/wlan.ko
/root/cnss_utils.ko

/lib/firmware/qcom/sm4450/xiaomi-sky/wpss.mdt          ← 11 wpss segments go here
/lib/firmware/qcom/sm4450/xiaomi-sky/wpss.b00 … b10

/lib/firmware/adrastea/regdb.bin
/lib/firmware/adrastea/bdwlant_jp.bin
/lib/firmware/adrastea/bdwlant_cn.bin

/lib/firmware/wlan/qca_cld/WCNSS_qcom_cfg.ini          ← must be exactly this path
```
Optional redundancy that also works: `/vendor/firmware/wlan/qca_cld/WCNSS_qcom_cfg.ini`
and `/vendor/etc/wifi/adrastea/WCNSS_qcom_cfg.ini`.

## 3. Copy the files

Over SSH (device at `192.168.7.1`, password `sky`):

```sh
DST=root@192.168.7.1
ssh $DST 'mkdir -p /lib/firmware/adrastea /lib/firmware/wlan/qca_cld \
                   /lib/firmware/qcom/sm4450/xiaomi-sky'

scp wlan.ko icnss2.ko wlan_firmware_service.ko cnss_utils.ko $DST:/root/
scp wpss.*                       $DST:/lib/firmware/qcom/sm4450/xiaomi-sky/
scp regdb.bin bdwlant_jp.bin bdwlant_cn.bin $DST:/lib/firmware/adrastea/
scp WCNSS_qcom_cfg.ini           $DST:/lib/firmware/wlan/qca_cld/
ssh $DST 'cp /lib/firmware/qcom/sm4450/xiaomi-sky/wpss.mdt \
             /lib/firmware/qcom/sm4450/xiaomi-sky/wpss.mbn'   # remoteproc uses .mbn
```

### 3.1 **Always verify the transfer** (mandatory)

A flaky USB link produces files with the *correct size* but **all-zero content**, which
makes the firmware reject the BDF download with `result=1, err=1`. Verify every file:

```sh
ssh $DST 'md5sum /root/*.ko /lib/firmware/adrastea/* /lib/firmware/wlan/qca_cld/*.ini'
# compare against §1; also spot-check the ini is not empty:
ssh $DST 'head -3 /lib/firmware/wlan/qca_cld/WCNSS_qcom_cfg.ini'
ssh $DST 'sync; sync'
```

## 4. Checksums (full firmware set)

```
76e33e9557f8cbd378a9511893360caa  wpss.b00
c6d47c06992d1a7426e894c0414ba2bc  wpss.b01
93fef43e6d88964b26e3d986804bfca7  wpss.b02
3b7b29e231500a784f8b1f5ca144a0ab  wpss.b03
65749df6a5fd61c9dc52499d5ad8c64d  wpss.b04
3a8a71832f5bb9c5c86cf56df8b35edb  wpss.b05
baf60a062c25f9612fb8fb7cc6e6ede7  wpss.b06
6df19b28568faebacbf769cd27a05457  wpss.b07
452720a28242354f3453ce7a152c3a24  wpss.b08
63d1098a44d1da304f9851a3f77bf6d8  wpss.b10
ccf4f902e92fd04fc6319671d5933090  wpss.mdt
```

## 5. Load (order matters — one load per boot)

```sh
insmod /root/wlan_firmware_service.ko     # exports the wlfw_* QMI tables (93 symbols)
insmod /root/icnss2.ko                    # platform glue: QMI + remoteproc + regulators
# wait ~8 s
insmod /root/wlan.ko                      # qcacld: creates wlan0
```

`icnss2.ko` must come **after** `wlan_firmware_service.ko` (otherwise:
`Unknown symbol wlfw_*_ei`). `wlan.ko` must come **after** `icnss2.ko`.

## 6. Expected output (good run)

```
icnss2: Platform driver probed successfully
icnss2_qmi: QMI Server Connected: state: 0x480
fw_version: 0x3431fb72, fw_build_timestamp: 2024-09-03 13:50,
            fw_build_id: WLAN.HL.3.4.3-00346-QCAHLSWMTPLZ-1.31602.10
Downloading REGDB: adrastea/regdb.bin, size: 19348
Downloading BDF:   adrastea/bdwlant_cn.bin, size: 26328
icnss2_qmi: Sending cal report request, state: 0x483
icnss2: WLAN FW is ready: 0x487
wlan: Loading driver v2.0.9.17N +PANIC_ON_BUG
```

Then:

```sh
ip link set wlan0 up
iw dev                      # phy#0, Interface wlan0, type managed, addr ...
iw dev wlan0 scan | head    # list of BSS
```

## 7. Verify

```sh
lsmod | grep -E 'wlan|icnss2|wlan_firmware'
# wlan 8486912 - ; icnss2 143360 - ; wlan_firmware_service 69632 -

dmesg | grep -c 'WLAN FW is ready'      # 1
ip link show wlan0                      # state UP / NO-CARRIER
iw dev wlan0 scan | grep -c '^BSS'      # >0
```

## 8. Reloading / rebooting

`CONFIG_MODULE_UNLOAD=n` ⇒ `rmmod` fails with `Function not implemented`.
To retry, reboot:

```sh
sync; sync; sleep 1; echo b > /proc/sysrq-trigger
```
`sync` first is important — without it the rootfs may lose recently written files.
The plain `reboot` command has been observed to hang on this setup.

## 9. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `invalid module format` | vermagic ≠ running kernel, or corrupted transfer (md5!) |
| `Unknown symbol wlfw_*_ei` | `wlan_firmware_service.ko` not loaded first |
| `icnss2: Fail to get IRQ-0` | DT lacks IRQ resources / old icnss2 build without the `platform_get_irq()` fix |
| probe returns `-1`, no qcacld logs | `WCNSS_qcom_cfg.ini` missing from `/lib/firmware/wlan/qca_cld/` |
| BDF/REGDB download `result=1, err=1` | firmware files are empty (USB corruption) — re-copy + md5 |
| `WARNING ... __netif_napi_del_locked` during idle shutdown | known, benign: qcacld deletes NAPI without `napi_disable()`; does not affect operation |
| no `wlan0` | check `dmesg \| sed -n '/Loading driver/,+40p'` |
| device lands in fastboot | `fastboot flash boot_a out/sky-shim-boot-v4.img` + `fastboot reboot` |

## 10. Rollback

Everything lives in files; removing them restores the previous state:

```sh
rm -f /root/{wlan,icnss2,wlan_firmware_service,cnss_utils}.ko
rm -rf /lib/firmware/adrastea
rm -f  /lib/firmware/wlan/qca_cld/WCNSS_qcom_cfg.ini
reboot
```
No persistent state is written by the driver except `/data/vendor/wifi/**` (logs, pktlog).
