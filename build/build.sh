#!/bin/sh
# 一键构建 icnss2 + wlan_firmware_service + qcacld(wlan.ko)
# 用法：KERNEL_SRC=/path/to/linux-7.3 ./build.sh [deps|platform|wlan|all]
set -e
[ -n "$KERNEL_SRC" ] || { echo "请设置 KERNEL_SRC 指向 Linux 7.3 内核树" >&2; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
STEP=${1:-all}

run() { make -C "$ROOT/src/icnss2" -f port.mk KERNEL_SRC="$KERNEL_SRC" "$@"; }

case "$STEP" in
  deps)     run dependencies ;;
  platform) run platform ;;
  wlan)     run WLAN_DIR="$ROOT/src/qcacld-3.0" wlan ;;
  all)      run dependencies
            run platform
            run WLAN_DIR="$ROOT/src/qcacld-3.0" wlan ;;
  *) echo "未知步骤: $STEP" >&2; exit 1 ;;
esac

echo "--- 产物 ---"
ls -l "$ROOT/src/icnss2"/*.ko "$ROOT/src/icnss2/drivers/soc/qcom/icnss2/icnss2.ko" \
      "$ROOT/src/qcacld-3.0/wlan.ko" 2>/dev/null
echo "--- vermagic ---"
for f in "$ROOT/src/icnss2/drivers/soc/qcom/icnss2/icnss2.ko" "$ROOT/src/qcacld-3.0/wlan.ko"; do
  printf "%-70s %s\n" "$(basename "$f")" "$(strings "$f" | grep -m1 'vermagic=')"
done
