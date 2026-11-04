# 构建说明（sky / SM4450 + WCN6750 adrastea，Linux 7.3 主线）

本文覆盖**完整构建链**：内核 → DTB → 三个内核模块（`wlan_firmware_service`、`icnss2`、`wlan`）
→ 启动镜像打包。所有命令都在 x86_64 主机上交叉编译，目标 `arm64`。

---

## 1. 环境要求（实测可用的版本）

| 项 | 值 |
|---|---|
| 内核源码 | Linux **7.3.0**，`git describe` = `78458d4ee-dirty`（本机定制树） |
| 目标 vermagic | `7.3.0-g78458d4eea4e-dirty SMP preempt aarch64` |
| 交叉编译器 | `aarch64-linux-gnu-gcc` **13.3.0**（Ubuntu 13.3.0-6ubuntu2~24.04.1） |
| binutils | GNU ld **2.42** |
| 主机 | x86_64 Ubuntu 24.04 |

> **vermagic 必须与目标内核完全一致**，否则 `insmod` 报 `invalid module format`。
> 换内核 → 必须重编这三个模块。

内核 config 相关片段见 `kernel-config-sky-7.3.fragment`，关键项：
`CONFIG_MODULES=y`、`CONFIG_CFG80211=y`、`CONFIG_QRTR`、`CONFIG_QMI_HELPERS`（`linux/soc/qcom/qmi.h`）、
`CONFIG_REMOTEPROC` + `QCOM_Q6V5_PAS`（wpss）、`CONFIG_ARM_SMMU`、`CONFIG_MODULE_SIG=n`、
`CONFIG_MODVERSIONS=n`（有 modversions 时 `Module.symvers` 必须成对匹配）。

## 2. 源码树布局

仓库内已包含全部源码，构建时通过 `KERNEL_SRC` 指向外部的 Linux 7.3 内核树：

```
src/icnss2/                 ← 构建入口在 port.mk（本目录）
  drivers/soc/qcom/icnss2/  ← icnss2 源码（main.c/qmi.c/power.c/...）
  wlan_firmware_service_v01.{c,h}   ← WLFW QMI 服务定义（导出 wlfw_*_ei）
  cnss_utils.c / cnss_plat_ipc_*    ← dependencies 目标产物
src/qcacld-3.0/             ← qcacld（含 cmn → ../qca-wifi-host-cmn 符号链接）
src/qca-wifi-host-cmn/      ← 共享组件（HIF/CE/QDF）
```

⚠️ `port.mk` 里的默认 `KERNEL_SRC` 指向开发者本机路径，**必须显式覆盖**：
`KERNEL_SRC=/path/to/linux-7.3`。

## 3. 三步构建（顺序不能乱）

```sh
export KERNEL_SRC=/path/to/linux-7.3

# (1) 依赖模块：cnss_utils.ko 等；生成 src/icnss2/Module.symvers
make -C src/icnss2 -f port.mk KERNEL_SRC=$KERNEL_SRC dependencies

# (2) 平台模块：icnss2.ko（依赖上一步的 Module.symvers，通过 KBUILD_EXTRA_SYMBOLS）
make -C src/icnss2 -f port.mk KERNEL_SRC=$KERNEL_SRC platform

# (3) 主驱动：wlan.ko（依赖 icnss2 的 Module.symvers，且会先重跑 platform）
make -C src/icnss2 -f port.mk KERNEL_SRC=$KERNEL_SRC \
     WLAN_DIR=$PWD/src/qcacld-3.0 wlan
```

或一键：`KERNEL_SRC=/path/to/linux-7.3 ./build/build.sh all`

### 关键编译开关（`port.mk` 里已固化）

```make
WLAN_CONFIG := CONFIG_ICNSS2=y CONFIG_QMI_SUPPORT=y CONFIG_PLD_SNOC_ICNSS_FLAG=y \
               CONFIG_WIFI_3_0_ADRASTEA=y CONFIG_ADRASTEA_SHADOW_REGISTERS=y \
               CONFIG_ADRASTEA_RRI_ON_DDR=y CONFIG_HIF_SNOC=y
# platform 目标额外加
KCFLAGS='-DCONFIG_ICNSS2_QMI -DCONFIG_ICNSS2_ADRASTEA_MAINLINE'
```

* `CONFIG_ICNSS2_QMI=y`：**必须**。否则会走 stock 的零返回 stub，QMI 全部假成功。
* `CONFIG_ADRASTEA_SHADOW_REGISTERS=y`：adrastea 的 CE 写指针走 SR_APSS 影子槽，
  这是本平台能工作的前提（mainline 上已实测：`ADDRESS_VALID=0xf860b9`）。
* `CONFIG_HIF_SNOC=y`：SNOC 总线（不是 PCIe）。

## 4. 产物与校验

| 产物 | 路径 | 大小（实测） |
|---|---|---|
| `wlan_firmware_service.ko` | `src/icnss2/` | 134,920 B |
| `cnss_utils.ko` | `src/icnss2/` | 79,840 B |
| `icnss2.ko` | `src/icnss2/drivers/soc/qcom/icnss2/` | 809,992 B |
| `wlan.ko` | `src/qcacld-3.0/` | 62,484,880 B |

```sh
# vermagic 自检
for f in src/icnss2/drivers/soc/qcom/icnss2/icnss2.ko src/qcacld-3.0/wlan.ko; do
  strings $f | grep -m1 vermagic=
done
# 与设备内核对比
ssh root@<device> 'uname -r'      # 必须与 vermagic 前缀一致
```
`modules/` 目录里的 `.ko` 是**已验证可加载**的快照（md5 见 `versions.txt`）。

## 5. 设备树（DTB）

`dts/sm4450-xiaomi-sky.dts` 需要用 **cpp 预处理 + dtc** 编译（不能直接 dtc）：

```sh
K=$KERNEL_SRC
cpp -nostdinc -I $K/include -I $K/arch/arm64/boot/dts/qcom -I dts \
    -undef -x assembler-with-cpp dts/sm4450-xiaomi-sky.dts -o /tmp/sky.pre.dts
dtc -I dts -O dtb -o /tmp/sky.dtb /tmp/sky.pre.dts
```
⚠️ **不要**用上游的 `tools/mksky_dts.py` 重新生成 DTS（会覆盖手工修改）。

## 6. 启动镜像打包

用 shim 的官方打包脚本（**不要**用固定偏移覆写的方式，会 overlap 导致 `HALT payload did not start Linux`）：

```sh
./shim/make-m1.sh $KERNEL_SRC/arch/arm64/boot/Image /tmp/sky.dtb
# 产物 out/sky-shim-boot-v4.img，正确大小应为 120,086,528 B
```
刷入：`fastboot flash boot_a out/sky-shim-boot-v4.img` 或设备上
`dd if=img of=/dev/sde13 bs=4096`（boot_a）。

## 7. 部署到设备

```sh
# 固件（必须，且必须 md5 校验：USB 链路不稳时会出现"大小对、内容全零"）
/lib/firmware/qcom/sm4450/xiaomi-sky/wpss.*            ← 从 ROM NON-HLOS.bin 提取
/lib/firmware/adrastea/{regdb.bin,bdwlant_cn.bin,bdwlant_jp.bin}
/lib/firmware/wlan/qca_cld/WCNSS_qcom_cfg.ini          ← 路径敏感，必须是这个目录
# 可选冗余（实测有效）：/vendor/firmware/wlan/qca_cld/ 同名文件

# 加载（CONFIG_MODULE_UNLOAD=n ⇒ 一次开机只能加载一次）
insmod wlan_firmware_service.ko
insmod icnss2.ko        # 等 ~8s：期望 "WLAN FW is ready: 0x487"
insmod wlan.ko          # 期望 wlan0 出现
ip link set wlan0 up && iw dev wlan0 scan
```

## 8. 常见错误对照

| 现象 | 原因 / 处理 |
|---|---|
| `icnss2: Fail to get IRQ-0` | 用了 `platform_get_resource(IORESOURCE_IRQ)`；本平台设备无资源表，改 `platform_get_irq()` |
| probe 返回 `-1`，无任何日志 | `cfg_parse("wlan/qca_cld/WCNSS_qcom_cfg.ini")` 失败 → ini 不在 `/lib/firmware/wlan/qca_cld/` |
| `netif_napi_add_weight_locked` oops | `qca_napi_info.netdev` 未初始化 → 手工 `INIT_LIST_HEAD(&dev->napi_list)` |
| `invalid module format` | vermagic 不匹配 / 传输损坏（md5 校验） |
| `Unknown symbol wlfw_*_ei` | 未先加载 `wlan_firmware_service.ko`（它导出 93 个 `wlfw_*`） |
| BDF 下载 `result=1, err=1` | 固件文件内容为空（USB 传输损坏）→ md5 双向校验 |
| 落进 fastboot | `fastboot flash boot_a out/sky-shim-boot-v4.img` + `fastboot reboot` |

## 9. 调试插桩（本次定位问题时加的，正式版可移除）

`patch/*.patch` 里包含：

* `wlan_hdd_driver_ops.c.patch` —— `hdd_soc_probe()`（含 `osif_psoc_sync_create_and_trans`）
  与 `__hdd_soc_probe()` 五步 + `hdd_psoc_create_vdevs` 的 `sky-dbg:` 打印；
* `wlan_hdd_main.c.patch` —— `hdd_context_create()` 内部 8 个子步骤的 `sky-dbg2:` 打印；
* `hif_napi.c.patch` —— NAPI `net_device` 初始化修复。

另外 icnss2 侧还有三处改动（无 .bak，改动点记录在此）：
`main.c` 的 IRQ 获取方式、`qmi.c` 的 BDF 首段字段打印 + `ath11k_bdf_chunk` 分片上限、
`debug.h` 的 `icnss_pr_dbg` 提升为 `printk(KERN_INFO)`。

## 10. 已知限制

* 未做连接（WPA2/WPA3）、DHCP、吞吐、SSR 恢复验证。
* `wlan.ko` 62 MB，包含调试符号；量产可 `strip --strip-debug`。
* 仅验证过本机（Redmi 12 5G / sky，JP 版固件 2024-09）。
