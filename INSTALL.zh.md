# 安装教程 —— sky（Redmi 12 5G）WLAN 模块（Linux 7.3）

在运行 mainline Linux **7.3** 的小米 Redmi 12 5G（`sky`，SM4450 + WCN6750 “adrastea”）
上安装主线化后的 **qcacld-3.0 + icnss2** WLAN 驱动栈。

> English version: [`INSTALL.md`](INSTALL.md)

---

## 0. 前置条件（先确认）

| 项 | 值 | 检查方式 |
|---|---|---|
| 设备 | 小米 Redmi 12 5G / `sky`（SM4450，WCN6750 adrastea） | `cat /proc/device-tree/model` |
| 内核 | **必须** `7.3.0-g78458d4eea4e-dirty` | `uname -r` |
| 模块 vermagic | `7.3.0-g78458d4eea4e-dirty SMP preempt aarch64` | `strings wlan.ko \| grep vermagic` |
| 内核配置 | 本构建 `CONFIG_MODULE_UNLOAD=n` ⇒ **一次开机只能加载一次** | — |
| 设备树 | 必须含 `qcom,icnss` 节点（12 条 CE 中断、MSA 12 MiB） | `ls /proc/device-tree/soc@0 \| grep wifi` |
| 权限 | root shell（SSH 或 adb） | — |

⚠️ 若 `uname -r` 与 vermagic 不一致，模块**加载不了**（`invalid module format`），
请按 `build/BUILD.md` 重新编译。

## 1. 需要安装的文件（均已 md5 校验）

```
wlan.ko                     3adcf546046b5aa2295ecc5f9a63db17   62,484,880 B
icnss2.ko                   e279bc58c257a69dafac3c914b2f34e1      809,992 B
wlan_firmware_service.ko    e468d18624449535676e4fd583fbdc80      134,920 B
cnss_utils.ko               4263db5976a511b66354dc4758a8ab2a       79,840 B

固件（adrastea）：
wpss.mdt                    ccf4f902e92fd04fc6319671d5933090        4,684 B
wpss.b00 … wpss.b10         （校验值见 §4）
regdb.bin                   8889032e43d7228d6b1ad1e8c33cf73d       19,348 B
bdwlant_jp.bin              e8d5ed7ac1910a65c990640204b27cb8       26,328 B
bdwlant_cn.bin              3ea6e413fe84a33844d0fde2906724bf       26,328 B
WCNSS_qcom_cfg.ini          936d61551e133a65197d5a9b354b7d8e       13,913 B
```

## 2. 设备上的目标路径

```
/root/wlan_firmware_service.ko
/root/icnss2.ko
/root/wlan.ko
/root/cnss_utils.ko

/lib/firmware/qcom/sm4450/xiaomi-sky/wpss.mdt        ← 11 个 wpss 段都放这里
/lib/firmware/qcom/sm4450/xiaomi-sky/wpss.b00 … b10

/lib/firmware/adrastea/regdb.bin
/lib/firmware/adrastea/bdwlant_jp.bin
/lib/firmware/adrastea/bdwlant_cn.bin

/lib/firmware/wlan/qca_cld/WCNSS_qcom_cfg.ini        ← 必须是这个路径
```
可选冗余（实测同样有效）：`/vendor/firmware/wlan/qca_cld/WCNSS_qcom_cfg.ini`、
`/vendor/etc/wifi/adrastea/WCNSS_qcom_cfg.ini`。

## 3. 拷贝文件

SSH（设备 `192.168.7.1`，密码 `sky`）：

```sh
DST=root@192.168.7.1
ssh $DST 'mkdir -p /lib/firmware/adrastea /lib/firmware/wlan/qca_cld \
                   /lib/firmware/qcom/sm4450/xiaomi-sky'

scp wlan.ko icnss2.ko wlan_firmware_service.ko cnss_utils.ko $DST:/root/
scp wpss.*                       $DST:/lib/firmware/qcom/sm4450/xiaomi-sky/
scp regdb.bin bdwlant_jp.bin bdwlant_cn.bin $DST:/lib/firmware/adrastea/
scp WCNSS_qcom_cfg.ini           $DST:/lib/firmware/wlan/qca_cld/
ssh $DST 'cp /lib/firmware/qcom/sm4450/xiaomi-sky/wpss.mdt \
             /lib/firmware/qcom/sm4450/xiaomi-sky/wpss.mbn'   # remoteproc 用 .mbn
```

### 3.1 **必须校验传输结果**

USB 链路不稳时会出现「大小正确、内容全零」的文件，固件会因此拒绝 BDF 下载
（`result=1, err=1`）。逐个校验：

```sh
ssh $DST 'md5sum /root/*.ko /lib/firmware/adrastea/* /lib/firmware/wlan/qca_cld/*.ini'
# 与 §1 对照；再确认 ini 不是空文件：
ssh $DST 'head -3 /lib/firmware/wlan/qca_cld/WCNSS_qcom_cfg.ini'
ssh $DST 'sync; sync'
```

## 4. 完整固件校验值

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

## 5. 加载（顺序不能错，一次开机一次）

```sh
insmod /root/wlan_firmware_service.ko     # 导出 93 个 wlfw_* QMI 表
insmod /root/icnss2.ko                    # 平台胶水：QMI + remoteproc + 稳压器
# 等约 8 秒
insmod /root/wlan.ko                      # qcacld 主驱动，创建 wlan0
```

`icnss2.ko` 必须在 `wlan_firmware_service.ko` **之后**（否则 `Unknown symbol wlfw_*_ei`）；
`wlan.ko` 必须在 `icnss2.ko` **之后**。

## 6. 正常输出（成功的样子）

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

随后：

```sh
ip link set wlan0 up
iw dev                      # phy#0、Interface wlan0、type managed、addr …
iw dev wlan0 scan | head    # 列出周边 BSS
```

## 7. 验证

```sh
lsmod | grep -E 'wlan|icnss2|wlan_firmware'
# wlan 8486912 - ; icnss2 143360 - ; wlan_firmware_service 69632 -

dmesg | grep -c 'WLAN FW is ready'      # 应为 1
ip link show wlan0                      # state UP / NO-CARRIER
iw dev wlan0 scan | grep -c '^BSS'      # 大于 0
```

## 8. 重新加载 / 重启

`CONFIG_MODULE_UNLOAD=n` ⇒ `rmmod` 报 `Function not implemented`，只能重启：

```sh
sync; sync; sleep 1; echo b > /proc/sysrq-trigger
```
**先 sync 很重要**，否则刚写入的文件可能丢失。本机实测 `reboot` 命令会挂住，别用。

## 9. 故障排查

| 现象 | 原因 / 处理 |
|---|---|
| `invalid module format` | vermagic 与运行内核不符，或传输损坏（校验 md5） |
| `Unknown symbol wlfw_*_ei` | 没有先加载 `wlan_firmware_service.ko` |
| `icnss2: Fail to get IRQ-0` | DT 缺 IRQ 资源，或用了未打 `platform_get_irq()` 修复的旧 icnss2 |
| probe 返回 `-1`、qcacld 无日志 | `WCNSS_qcom_cfg.ini` 不在 `/lib/firmware/wlan/qca_cld/` |
| BDF/REGDB 下载 `result=1, err=1` | 固件文件内容为空（USB 损坏）→ 重传 + md5 |
| idle shutdown 时 `WARNING ... __netif_napi_del_locked` | 已知且良性：qcacld 删 NAPI 前没 `napi_disable()`，不影响功能 |
| 没有 `wlan0` | 看 `dmesg \| sed -n '/Loading driver/,+40p'` |
| 设备落进 fastboot | `fastboot flash boot_a out/sky-shim-boot-v4.img` + `fastboot reboot` |

## 10. 卸载 / 回滚

所有内容都是文件，删掉即恢复原状：

```sh
rm -f /root/{wlan,icnss2,wlan_firmware_service,cnss_utils}.ko
rm -rf /lib/firmware/adrastea
rm -f  /lib/firmware/wlan/qca_cld/WCNSS_qcom_cfg.ini
reboot
```
驱动唯一会写的持久状态是 `/data/vendor/wifi/**`（日志 / pktlog）。
