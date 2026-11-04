# Working state — WiFi associated and on the Internet (2026-11-04)

## Result

```
wpa_supplicant 2.10-r11 on wlan0 (-D nl80211)
wpa_cli status : wpa_state=COMPLETED
                 ssid=TP-Link_FD895G  bssid=78:8c:b5:82:fd:88  key_mgmt=WPA2-PSK
udhcpc         : lease of 192.168.1.186 obtained from 192.168.1.1
ping 1.1.1.1   : 3/3 packets, 0% loss, 5.1–16.5 ms
```

⇒ full cfg80211 association + 4-way handshake + DHCP + IP traffic work with the
mainlined qcacld-3.0/icnss2 stack on Linux 7.3.

## Boot integration (Alpine rootfs)

PID 1 is a custom `/bin/sh /init` (no inittab, no OpenRC initially), so a plain
`inittab` hook did not work. Final setup:

1. **OpenRC installed** (`apk add openrc wpa_supplicant-openrc`, needs a correct clock —
   the device RTC starts at 1970, `date -u -s` from the host first, otherwise TLS fails).
2. **OpenRC service** `/etc/init.d/sky-wifi` (in `install/sky-wifi.initd`),
   enabled in the `default` runlevel: `rc-update add sky-wifi default`.
3. **`/init` patched** (backup `/init.bak-20261104`):

```sh
# WLAN: load immediately in background (idempotent), OpenRC service sky-wifi is the fallback
/usr/local/sbin/sky-wifi-load.sh </dev/null >/dev/null 2>&1 &
mkdir -p /run/openrc && touch /run/openrc/softlevel     # OpenRC in "soft" mode (PID1 is not openrc)
/sbin/openrc default >/dev/null 2>&1
```

4. **Loader script** `/usr/local/sbin/sky-wifi-load.sh` (in `install/sky-wifi-load.sh`):
   verifies files are non-empty → loads `wlan_firmware_service` → `icnss2`
   (waits ≤20 s for `WLAN FW is ready`) → `wlan` → `wlan0 up` →
   starts `wpa_supplicant` (if the config has a `network={}` block) →
   waits for `wpa_state=COMPLETED` → `udhcpc` if no IPv4 address.
   It is idempotent: if the modules are already loaded it only re-establishes the link.
   Everything is logged to `/log/wifi-load.log`.

## Notes / caveats

* `rc-service sky-wifi start` inside the current boot may report
  `WARNING: sky-wifi is already starting` — stale OpenRC state in `/run/openrc`
  from earlier manual attempts; `/run` is a tmpfs, so a reboot clears it.
* The fallback direct call in `/init` guarantees WiFi even if OpenRC misbehaves.
* `CONFIG_MODULE_UNLOAD=n` ⇒ exactly one module load per boot.
* Clock: set the time before using `apk` (TLS). Optionally add an NTP client later.
