# 交接：把 `/init` 的全部功能迁移到 OpenRC 服务

> 本文件面向「网络修复」专项 prompt。目标不是再调 WiFi，而是**把整机启动逻辑从
> `/init` 里搬出来，交给 OpenRC 管理**，让 `/init` 退化成最小 stub。
> WiFi（qcacld）本身已经跑通并接入互联网，见 `STATE-2026-11-04-connected.md`。

---

## 1. 现状快照（2026-11-04，设备实测）

| 项 | 现状 |
|---|---|
| PID 1 | `/bin/busybox` 执行 `/bin/sh /init`（**自定义脚本**，不读 `/etc/inittab`） |
| OpenRC | 已安装 `openrc 0.55.1-r2`（`apk add openrc wpa_supplicant-openrc`） |
| `/sbin/openrc-init` | **不存在**（`apk info -L openrc \| grep openrc-init` 需再确认；当前无法让 openrc 当 PID1） |
| `/etc/init.d` | 存在，含 Alpine 自带服务 + 自建 `sky-wifi`（完整列表见 §7） |
| runlevel | 只有 `default` 里有 `sky-wifi`；`sysinit`/`boot`/`shutdown` **都是空的** |
| 调用方式 | `/init:35-36` 里 `touch /run/openrc/softlevel` + `/sbin/openrc default`（soft 模式） |
| `/rootfs` | Alpine 3.21.9（musl），模块/固件都在 rootfs 内 |

⚠️ 因为 PID 1 不是 openrc，OpenRC 只能以 **soft 模式**工作，
`rc-service XXX start` 会报 `WARNING: sky-wifi is already starting`（状态粘住），
`/run` 是 tmpfs，重启才清。这是**迁移要解决的头号问题**。

## 2. `/init` 当前承担的全部功能（逐行清单）

| # | 行号 | 功能 | 依赖 | 建议迁往 |
|---|---|---|---|---|
| 1 | 7-18 | **ADSP remoteproc 重试启动**（后台，60×2s）：`echo start > /sys/class/remoteproc/*/state` | `/lib/firmware/adsp/*` 可读 | 新服务 `adsp-rproc`（`after localmount`，`start` 里后台循环重试） |
| 2 | 19-25 | **挂载 proc/sysfs/devtmpfs/devpts/tmpfs(/dev/shm)** + `mkdir /run/sshd /var/empty /log` | — | Alpine 自带 `sysfs`/`procfs`/`devfs` + `bootmisc`（在 `sysinit`/`boot` runlevel）；`/log`、`/var/empty` 由 `bootmisc`/新服务补 |
| 3 | 27-36 | **WLAN 加载**：后台跑 `sky-wifi-load.sh`，并 `openrc default` | 固件、模块 | **已迁完**：`/etc/init.d/sky-wifi`（`need localmount` 已删）。迁移后应删掉 `/init` 里的后台直调，只留 `exec openrc` |
| 4 | 38-39 | **insmod 面板/触屏模块**：`ktd3136.ko`、`panel-xiaomi-m19.ko clock_khz=$(cat /etc/sky-panel-clock)` | `/lib/modules/$(uname -r)/extra/` | `/etc/modules`（OpenRC `modules` 服务）或新服务 `sky-panel`（需要参数，建议新服务） |
| 5 | 40 | **hostname sky** | — | Alpine `hostname` 服务（`/etc/hostname`） |
| 6 | 42-46 | **usb0 静态地址**：`ip link set usb0 up` + `ip addr add 192.168.7.1/24` | initramfs 已建好 gadget | `networking` 服务（`/etc/network/interfaces`，ifupdown-ng 已装）或新服务 `usbnet` |
| 7 | 48-59 | **udhcpd 服务端**：heredoc 写 `/run/udhcpd.conf`（池 192.168.7.10-50，router/dns=192.168.7.1），然后 `udhcpd` | `/usr/sbin/udhcpd`、usb0 | 新服务 `usb-dhcpd`（`need usbnet`）；注意 `/run` 是 tmpfs，conf 必须每启动生成 |
| 8 | 61-65 | **sshd 重启**：`pkill -f /sbin/sshd`（杀掉 initramfs 继承的）、`ssh-keygen -A`、`/usr/sbin/sshd` | 主机密钥 | 新服务 `sshd`（Alpine 的 openssh 包没装 → 目前**没有** sshd 服务脚本，需自写） |
| 9 | 66 | **kmsg 启动横幅**（IP 信息） | — | `local` 服务或 `bootmisc` 之后的自定义 `sky-banner` |
| 10 | 68-74 | **/dev/ttyGS0 上的 root shell 常驻循环**（`setsid sh`，掉线重开） | USB 串口 gadget | 新服务 `ttygs0-shell`（`start` 里 `start-stop-daemon --background`）或改用 `agetty`（若 `agetty` 存在） |
| 11 | 76-94 | **电源键背光开关循环**：读 `/dev/input/event1` 的 code 116，翻转 `/sys/class/backlight/ktd3136-backlight/brightness` | evdev、backlight | 新服务 `sky-powerkey`（`after sky-panel`） |

> `/init` 第 27-29 行是 **ath11k 时代的过时注释**，迁移时一并删除。

## 3. 迁移目标形态

### 推荐路线 A（彻底）：让 openrc 成为 PID 1

```
/init（initramfs 里或 rootfs 开头）
  └─ 只做：mount proc/sys/dev（得到 /proc /sys /dev）→ exec /sbin/openrc-init
```
* 需要 `/sbin/openrc-init`（当前**缺失**，先 `apk add openrc` 确认文件列表，或从
  Alpine 包内提取 `openrc-init` 放到 `/sbin/`）
* openrc-init 会把 `/etc/inittab` 当 getty 表用（里面已有 tty1-5 的 getty 行）
* 好处：`rc-service` / `rc-update` 全部正常工作，`softlevel` hack 可以删除
* 风险：一旦 openrc-init 起不来，整机没有 shell（救援要靠 fastboot 重刷 boot.img
  或改 `/init`）——**先把 `/init` 备份、准备好救援镜像**

### 路线 B（保守）：`/init` 保留为最小 stub

```
/init
  ├─ mount proc/sys/dev/devpts/shm
  ├─ mkdir -p /run /log /var/empty /run/sshd
  ├─ touch /run/openrc/softlevel
  └─ exec /sbin/openrc default        # 只跑 default runlevel
```
* 保持 soft 模式，`rc-service` 的 "already starting" 问题仍在（可接受）
* 所有功能靠 default runlevel 里的服务实现，`/init` 不再有业务逻辑

> 两条路线下，**服务内容是一样的**；差别只在谁当 PID1、跑哪个 runlevel。
> 建议：先把服务都建好（默认 runlevel 里能跑通），再考虑切 openrc-init。

## 4. 目标服务清单（建议实现）

| 服务 | 文件 | `depend()` | `start()` 要点 |
|---|---|---|---|
| `sky-wifi` | 已有 `install/sky-wifi.initd` | `after localmount` `provide wifi` `before net` | 调 `/usr/local/sbin/sky-wifi-load.sh`（幂等、带 `/run/sky-wifi.lock`、内含 WPSS 就绪等待 ≤90s + FW ready ≤30s + wpa_supplicant + udhcpc） |
| `sky-panel` | 新建 | `after modules` | `insmod ktd3136.ko`；`insmod panel-xiaomi-m19.ko clock_khz=$(cat /etc/sky-panel-clock \|\| echo 276180)` |
| `adsp-rproc` | 新建 | `after localmount` | 后台循环 ≤120s：`echo start > /sys/class/remoteproc/*/state`（只对 `name == adsp`），成功后退出 |
| `usbnet` | 新建（或用 `networking`） | `need localmount` `provide net` | `ip link set usb0 up`；`ip addr add 192.168.7.1/24 dev usb0`（用 `ip addr replace` 保证幂等） |
| `usb-dhcpd` | 新建 | `need usbnet` | 每次生成 `/run/udhcpd.conf`（池 .10-.50，router/dns 192.168.7.1）后启动 `udhcpd`；`stop()` 用 `start-stop-daemon --stop` |
| `sshd` | 新建 | `after usbnet` | `pkill -f /sbin/sshd`（清理 initramfs 继承）、`ssh-keygen -A`、`/usr/sbin/sshd` |
| `ttygs0-shell` | 新建 | `after localmount` | `start-stop-daemon --start --background` 跑一个 `while :; do setsid sh -c 'exec sh </dev/ttyGS0 >/dev/ttyGS0 2>&1'; sleep 1; done` 的包装脚本 |
| `sky-powerkey` | 新建 | `after sky-panel` | 后台循环读 `/dev/input/event1`，`code==116 && value==1` 时翻转 backlight |
| `sky-banner` | 新建（可选） | `after sshd sky-wifi` | 往 `/dev/kmsg` 打一行启动横幅（含 usb0/wlan0 的 IP） |

所有服务都用 `#!/sbin/openrc-run`，`start()` 里用 `ebegin/eend`，把日志写到 `/log/`。

## 5. 迁移顺序（每次只迁一个，重启验证）

1. `sky-panel`（最独立，失败只影响屏幕）→ 重启确认面板/触控仍在（`/dev/input/event*`、亮度可调）
2. `usbnet` + `usb-dhcpd`（**注意：这会动到你我之间的 SSH 通道**；
   建议先在 `/init` 里保留原逻辑，服务只做 `ip addr replace` 幂等操作，验证后再删 `/init` 段）
3. `sshd`（同上，风险高；先 `rc-service sshd start` 在已运行的会话里试，确认不断连）
4. `adsp-rproc`（影响电池/充电供应）
5. `ttygs0-shell`、`sky-powerkey`、`sky-banner`
6. 最后把 `/init` 精简到路线 A 或 B，并删除 §2 表格里已迁走的代码

每步验证命令：

```sh
rc-service <name> start ; rc-service <name> status
rc-update show default
tail -20 /log/<name>.log
# 重启后
rc-status            # 看服务状态
dmesg | grep -iE "panel|ktd3136|adsp|sshd"
```

## 6. 已知坑（务必写进服务实现）

1. **soft 模式状态粘住**：`rc-service X start` → `already starting`。
   `/run/openrc` 是 tmpfs，重启即清；迁移到路线 A 可根除。
2. **`need localmount` 会失败**：当前只跑 `default` runlevel，`boot` 没跑过。
   服务里用 `after localmount` 或干脆不加依赖。
3. **WPSS 未就绪时 `icnss2` 握手失败**：日志表现为 `WARN: FW ready not seen`、
   `wlan0` 不出现。`sky-wifi-load.sh` 已加 WPSS 就绪等待（≤90s），别删。
4. **模块只能加载一次**（`CONFIG_MODULE_UNLOAD=n`）：服务必须有"已加载则跳过"分支，
   否则第二次 insmod 返回 `EEXIST`。
5. **时钟是 1970**：`apk` 的 TLS 会失败（`certificate verify failed` → 表现为
   `Permission denied`）。装包前先 `date -u -s "<host UTC>"`。
6. **busybox `ip` 不支持 `-br`**：脚本里用 `ip -4 addr show` + `awk`。
7. **USB 链路不稳**：`scp` 会出现"大小对、内容全零"。任何推送后必须 `md5sum` 双向核对。
8. **`/init` 里的注释还写着 ath11k**，已过时（第 27-29 行）。

## 7. 当前可用的 init.d 服务（Alpine 自带 + 自建）

```
binfmt bootmisc cgroups consolefont devfs dmesg firstboot fsck functions.sh hostname
hwclock hwdrivers killprocs local localmount loopback machine-id modloop modules
mount-ro mtab net-online netmount networking numlock osclock procfs root runsvdir
s6-svscan save-keymaps save-termencoding savecache seedrng sky-wifi staticroute swap
swclock sysctl sysfs sysfsconf termencoding wpa_cli wpa_supplicant
```
注意：**没有 `sshd`、没有 `udhcpd`、没有 `agetty`/`ttyGS0`** 的服务脚本 → 需自写。

## 8. 关键文件与备份

| 路径 | 用途 |
|---|---|
| `/init` | 当前启动脚本；备份 `/init.bak-20261104` |
| `/etc/inittab` + `.bak-20261104` | busybox/openrc-init 用的 getty 表（当前不生效） |
| `/usr/local/sbin/sky-wifi-load.sh` | WLAN 加载脚本（幂等 + 锁 + WPSS 等待），仓库 `install/sky-wifi-load.sh` |
| `/etc/init.d/sky-wifi` | OpenRC 服务，仓库 `install/sky-wifi.initd` |
| `/log/wifi-load.log`、`/log/wifi-up.log`、`/log/kmsg-wpss.log` | 当前日志（`wifi-up.log` 是 ath11k 时代遗留） |
| `/etc/wpa_supplicant/wpa_supplicant.conf` | 已配置的 AP（TP-Link_FD895G，WPA2-PSK） |
| `/root/*.ko` | 4 个模块（wlan/icnss2/wlan_firmware_service/cnss_utils） |

## 9. 验收标准（网络专项）

* 重启后**无需人工干预**：`wlan0` 出现、`wpa_state=COMPLETED`、拿到 DHCP 地址、
  `ping 1.1.1.1` 通
* `usb0` 仍为 `192.168.7.1/24`，主机能拿到 `192.168.7.10-50` 的地址并 SSH 登录
* `rc-service sky-wifi status` 显示 `started`；`rc-update show default` 里能看到所有新服务
* `/init` 里**不再有**业务逻辑（只有挂载 / `exec openrc`）
* 重启 3 次结果一致（无 race、无重复加载）

## 10. 当前网络状态（供回归对照）

```
usb0 : 192.168.7.1/24（静态，DHCP 服务端给主机发 .10-.50）
wlan0: DHCP 192.168.1.186/24，网关 192.168.1.1
       wpa_state=COMPLETED，ssid=TP-Link_FD895G，bssid=78:8c:b5:82:fd:88
       默认路由 via 192.168.1.1 dev wlan0 metric 304
       ping 1.1.1.1: 0% loss，5-16 ms
```
