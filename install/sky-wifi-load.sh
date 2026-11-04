#!/bin/sh
# sky: load the mainlined qcacld-3.0 + icnss2 WLAN stack at boot.
# One load per boot only (CONFIG_MODULE_UNLOAD=n).
LOG=/log/wifi-load.log
M=/root
FW=/lib/firmware

log() { echo "sky-wifi-load: $*" >> "$LOG"; }

[ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt 200 ] && : > "$LOG"
log "=== $(date '+%F %T') start ==="

for f in $M/wlan_firmware_service.ko $M/icnss2.ko $M/wlan.ko \
         $FW/adrastea/regdb.bin $FW/adrastea/bdwlant_jp.bin \
         $FW/wlan/qca_cld/WCNSS_qcom_cfg.ini; do
    [ -s "$f" ] || { log "missing/empty: $f -> abort"; exit 1; }
done

[ -n "$(lsmod | grep '^wlan_firmware_service')" ] && { log "already loaded"; exit 0; }

insmod $M/wlan_firmware_service.ko || { log "insmod wlan_firmware_service FAILED"; exit 1; }
log "wlan_firmware_service loaded"

insmod $M/icnss2.ko || { log "insmod icnss2 FAILED"; exit 1; }
log "icnss2 loaded"

i=0
while [ $i -lt 40 ]; do
    dmesg | grep -q "WLAN FW is ready" && break
    i=$((i+1)); sleep 0.5
done
if dmesg | grep -q "WLAN FW is ready"; then
    log "WLAN FW is ready: $(dmesg | grep -m1 'WLAN FW is ready' | sed 's/.*: //')"
else
    log "WARN: FW ready not seen in 20s"
fi

insmod $M/wlan.ko || { log "insmod wlan FAILED"; exit 1; }
log "wlan loaded"

sleep 3
ip link set wlan0 up 2>/dev/null && log "wlan0 up"
log "wlan0: $(ip link show wlan0 2>/dev/null | head -1 | sed 's/^[0-9]*: //')"
log "=== done ==="
