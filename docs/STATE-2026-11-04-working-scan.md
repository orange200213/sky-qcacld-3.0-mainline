# Working state snapshot — 2026-11-04

## Verified working (on device)

```
kernel      : 7.3.0-g78458d4eea4e-dirty  (#112, FDT sha b1b0d1d7… = dts/sm4450-xiaomi-sky.dts)
modules     : wlan (62,484,880 B) / icnss2 (809,992) / wlan_firmware_service (134,920) / cnss_utils (79,840)
firmware    : /lib/firmware/adrastea/{regdb.bin,bdwlant_cn.bin,bdwlant_jp.bin}
              /lib/firmware/qcom/sm4450/xiaomi-sky/wpss.*  (2024-09 build, fw_version 0x3431fb72)
config      : /lib/firmware/wlan/qca_cld/WCNSS_qcom_cfg.ini (13,913 B, md5 936d6155…)
interface   : wlan0, MAC 00:0a:f5:a0:f6:c7, phy#0
```

* `icnss2` probe OK → `WLAN FW is ready: 0x487`
* `wlan0` created, `iw dev wlan0 scan` works
* `wpa_supplicant 2.10-r11` (Alpine) started on `wlan0` with `-D nl80211`;
  `wpa_cli status` → `wpa_state=DISCONNECTED`, control interface works
* `wpa_cli scan` + `scan_results` → 11 APs listed (2.4/5 GHz, WPA2-PSK etc.)

## Boot persistence (固化)

`install/sky-wifi-load.sh` is installed as `/usr/local/sbin/sky-wifi-load.sh` and hooked into
`/etc/inittab` right after the OpenRC boot line:

```
::sysinit:/sbin/openrc boot
::sysinit:/usr/local/sbin/sky-wifi-load.sh      ← added
::wait:/sbin/openrc default
```
(`/etc/inittab.bak-20261104` is the original.)

The script:
1. verifies the four `.ko` + `regdb`/`bdwlant_jp` + ini exist and are non-empty (aborts otherwise);
2. skips if `wlan_firmware_service` is already loaded (one load per boot);
3. loads `wlan_firmware_service` → `icnss2`, waits up to 20 s for `WLAN FW is ready`;
4. loads `wlan`, brings `wlan0` up;
5. logs everything to `/log/wifi-load.log`.

## Tooling installed on the device

| Tool | Source | Purpose |
|---|---|---|
| `iw 6.9` + `libnl3 3.11` | Alpine apk (installed offline from host) | scan / link inspection |
| `wpa_supplicant 2.10-r11` (incl. `wpa_cli`, `wpa_passphrase`) + `libssl3`/`libcrypto3`/`dbus-libs`/`pcsc-lite-libs` | Alpine apk (installed offline) | association test |
| `udhcpc` | busybox | DHCP client |

Install method (device has no internet): resolve deps from the Alpine v3.21 APKINDEX on a
host, download the `.apk` set, push, then `apk add --allow-untrusted --no-network *.apk`.

## Next: association test

Needs an SSID/PSK. Procedure:

```sh
wpa_passphrase "SSID" "PASSWORD" >> /etc/wpa_supplicant/wpa_supplicant.conf
wpa_cli -i wlan0 reconfigure
wpa_cli -i wlan0 status            # expect wpa_state=COMPLETED
udhcpc -i wlan0 -q                 # get an IP
ping -c3 1.1.1.1
```
Known APs visible from the device (2.4/5 GHz) — see scan output in the log.
