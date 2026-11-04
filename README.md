# sky-qcacld-3.0-mainline

Xiaomi Redmi 12 5G（`sky` / SM4450 `ravelin`）+ **WCN6750 `adrastea`**（SNOC）
上把 **qcacld-3.0 主线化（mainline 化）** 的工作记录、源码快照、模块与固件。

目标内核：**Linux 7.3**（mainline），非 Android、非 downstream 5.10。

---

## 1. 为什么不用 ath11k（本机 WiFi 的特殊性）

本项目最初的目标是 mainline `ath11k`（上游确实有 `ath11k_hw_wcn6750` / `qcom,wcn6750-wifi`）。
在真机上做了完整测量后确认**在这台设备上不可行**，原因是硬件/固件的寄存器访问模型：

| 实测结论 | 证据 |
|---|---|
| 8 MiB `membase`（`0x22800000`）窗口里，**只有 `0x20000..0x52000`（SR_APSS）可访问** | `membase+0x240000`(CE0)、`+0x24C000`(CE wrapper)、`+0x2xxxxx` 全部 DEAD；`0x22850000..0x23000000` 123 个探针 0 live |
| 主机唯一可写的寄存器通道 = **SR_APSS 影子槽** | `WLAN_CFG` 带 `shadow_reg`(v1) 12 条表后 `ADDRESS_VALID=0xf860b9`（12 槽），写 `SHADOW_VALUE[n]` 被硬件转发（`DIRTY` 消费、`INVALID_ADDR_ACCESS=0`） |
| 影子槽只覆盖 **CE 写指针**（0x3C/0x40） | 槽位映射 = `src CE 0/3/4/5/7 → slot 0/3/4/5/7`，`dst CE 1/2/7/8/9/10/11 → slot 13/14/19/20/21/22/23` |
| 主机**不能**编程 CE ring base/size、也不能碰 UMAC/WBM/REO/TCL | 零 MMIO 实验：把读写全过滤后，bring-up 只能跑到 HTC 然后超时 |
| 固件**不会**替主机建 CE 环 | 同上；且实测主机在收到 HTC ready 前根本不会踢写指针 |

⇒ mainline ath11k 的「主机编程 CE/DP 环」模型在这颗芯片上**不可能工作**；
原厂用的是 **qcacld-3.0 `adrastea` profile + icnss2**（数据面由固件自管）。
所以本项目改为：**把 qcacld-3.0 / icnss2 主线化到 Linux 7.3**。

> 完整的 ath11k 阶段记录（含所有实验、寄存器扫描、影子寄存器机制推导）在
> `docs/FINDINGS-session6..9-*.md` 与 `docs/HANDOFF-snoc-mainline.md`。

---

## 2. 当前成果

在 mainline 7.3 上：

```
icnss2: Platform driver probed successfully
fw_version: 0x3431fb72 (2024-09-03, WLAN.HL.3.4.3-00346-QCAHLSWMTPLZ-1.31602.10)
REGDB / BDF 下载成功（QMI WLFW）
cal report → icnss2: WLAN FW is ready: 0x487
wlan.ko 加载 → wlan0 (managed) 出现，MAC 00:0a:f5:a0:f6:c7
iw dev wlan0 scan → 成功列出周边 AP
```

已修复的三个真实 bug（详见 `docs/FINDINGS-qcacld-device-test-2026-11-04.md` §21）：

1. **icnss2 取 IRQ**：`platform_get_resource(pdev, IORESOURCE_IRQ, i)` → 平台设备无资源表；
   改 `platform_get_irq(pdev, i)`。
2. **qcacld `cfg_parse` 失败**：`WLAN_INI_FILE` 是相对路径 `wlan/qca_cld/WCNSS_qcom_cfg.ini`，
   需把 ini 放到 `/lib/firmware/wlan/qca_cld/` 与 `/vendor/firmware/wlan/qca_cld/`。
3. **NAPI oops**：`struct qca_napi_info` 内嵌 `net_device` 未初始化，7.3 的
   `netif_napi_add_weight_locked()` 会操作 `dev->napi_list`；`init_dummy_netdev()`
   未导出，改为手工 `INIT_LIST_HEAD(&dev->napi_list)` + `reg_state`。

补丁见 `patch/`，说明见 `docs/`。

---

## 3. 目录结构

```
README.md                    本文
docs/                        全部交接与实验记录（ath11k 阶段 + qcacld 阶段）
dts/                         sm4450-xiaomi-sky.dts（含 icnss 节点、触屏修复）+ attic 历史版
src/icnss2/                  icnss2 平台驱动源码 + wlan_firmware_service_v01.{c,h} + port.mk（构建入口）
src/qcacld-3.0/              qcacld-3.0 源码（已剔除 *.o/*.cmd 等构建中间件）
src/qca-wifi-host-cmn/       qcacld 共享组件源码（同上）
modules/                     已构建模块：wlan.ko / icnss2.ko / wlan_firmware_service.ko
firmware/                    日版原厂 adrastea 固件（NON-HLOS.bin 提取）+ regdb/BDF
patch/                       本次主线化所做的源码改动（unified diff）
```

## 4. 构建

```sh
# 依赖：Linux 7.3 内核树（KERNEL_SRC），aarch64 交叉工具链
cd src/icnss2
make -f port.mk dependencies     # cnss_utils / qmi 相关
make -f port.mk platform         # → icnss2.ko
make -f port.mk wlan             # → qcacld-3.0/wlan.ko
```
关键编译开关（`port.mk`）：
`CONFIG_ICNSS2=m CONFIG_ICNSS2_QMI=y CONFIG_PLD_SNOC_ICNSS_FLAG=y CONFIG_WIFI_3_0_ADRASTEA=y
CONFIG_ADRASTEA_SHADOW_REGISTERS=y CONFIG_ADRASTEA_RRI_ON_DDR=y CONFIG_HIF_SNOC=y`

## 5. 上机加载（一次开机只能加载一次，`CONFIG_MODULE_UNLOAD=n`）

```sh
# 固件与配置（必须）
#   /lib/firmware/qcom/sm4450/xiaomi-sky/wpss.*        （remote processor 固件）
#   /lib/firmware/adrastea/{regdb.bin,bdwlant_*.bin}    （QMI BDF 下载用）
#   /lib/firmware/wlan/qca_cld/WCNSS_qcom_cfg.ini       （qcacld ini，路径敏感）

insmod wlan_firmware_service.ko
insmod icnss2.ko            # 等 ~8s，期望 "WLAN FW is ready: 0x487"
insmod wlan.ko              # 期望 wlan0 出现
ip link set wlan0 up && iw dev wlan0 scan
```

## 6. 已知限制 / TODO

* 尚未做 WPA2/WPA3 连接、DHCP、吞吐测试。
* cfg80211 重点项未验证：ROC cookie、mgmt TX status、change_beacon、control-port、key 管理。
* SSR（WPSS 重启）恢复路径未验证。
* 模块只能在**匹配的内核**上加载（vermagic `7.3.0-g78458d4eea4e-dirty`），
  换内核需重新编译。
* 设备树依赖 `qcom,icnss` 节点（见 `dts/`），且 MSA 使用原厂 12 MiB 配置。
