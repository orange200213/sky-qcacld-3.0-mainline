# dts/ 目录说明（2026-11-04 合并）

## 最终版本

**`sm4450-xiaomi-sky.dts`** —— 唯一权威版本，`attic/` 里的是历史快照。

它由两份旧版合并而成：

| 来源 | 内容 | 合并处理 |
|---|---|---|
| `attic/sm4450-xiaomi-sky.ath11k-touchfix-2026-11-04.dts`（sky-mainline，11-04 12:28，曾实际运行） | 触屏修复：`panel = <&panel>`（DRM panel follower）、`pinctrl-names/‑0`；ath11k `wifi@22800000`（`qcom,wcn6750-wifi`）；`wpss.mbn`；MSA 3 MiB | 保留全部；ath11k 节点**整段注释停用**（与 icnss 互斥） |
| `attic/sm4450-xiaomi-sky.icnss-2026-11-03.dts`（sky-linux，11-03 17:01） | `qcom,icnss` 节点（12 管 CE 中断、`0x4c0` SMMU、`bdf-download-support`、`wpss-support-enable`、`qcom,fw-prefix`、稳压器）；`smp2p-wpss` 的 `wlan` 出入通道；MSA 12 MiB | icnss 节点与 smp2p wlan 通道并入；MSA 采用其 12 MiB |

## 合并后的关键差异

1. **icnss 节点已启用**（`status = "okay"`），ath11k 节点注释保留在文件内便于对照/回切；
   两者地址相同（`22800000`），DT 不允许同名节点，故只能二选一。
2. **MSA 保留区 = 12 MiB**（`0xc00000`，对齐原厂日版 ROM；旧值 3 MiB）。
3. **`smp2p-wpss` 增加 `wlan` 双向通道**（`wlan_smp2p_out` / `wlan_smp2p_in`），
   icnss 节点的 `qcom,smem-states` 与 `qcom,smp2p_map_wlan_1_in` 就指向它们。
4. **触屏修复原样保留**：`panel = <&panel>` + `pinctrl-names = "default"`。

## 编译方式（不是 `tools/mksky_dts.py`！）

`tools/mksky_dts.py` 会**重新生成并覆盖**本文件，不要用它。

```sh
K=kernel/linux-7.3
cpp -nostdinc -I $K/include -I $K/arch/arm64/boot/dts/qcom -I dts \
    -undef -x assembler-with-cpp dts/sm4450-xiaomi-sky.dts -o /tmp/sky.pre.dts
dtc -I dts -O dtb -o /tmp/sky.dtb /tmp/sky.pre.dts
```

2026-11-04 校验：编译通过（仅 2 条无害的 graph_child_address warning），
产物 **63,596 B**（合并前运行中 DTB 为 62,898 B）。

## 其他文件

* `sm4450-anbernic-plus.dts` —— Anbernic RG55G1 原始板级文件（`tools/mksky_dts.py` 的输入，保留）
* `minimal/` —— 早期最小 DTS 实验
* `attic/` —— 上述两份历史快照，只读保留，不要直接编译
