#!/bin/bash
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)

set -e

echo "========================================="
echo ">>> 开始执行 diy-part2.sh 完整自定义脚本"
echo "========================================="

# ------------------------------------------------------------
# 1. 配置 CPU 频率驱动 (采用源码原生 Patch + 开启内核 Config)
# ------------------------------------------------------------
echo ">>> [1/5] 正在配置 CPU 频率与 PM Domain 驱动..."

# 1. 彻底清理之前手动注入的 C 文件和 Makefile，避免冲突导致 Patch 失败
rm -rf target/linux/airoha/files/drivers/pmdomain/mediatek/airoha-cpu-pmdomain.c
rm -rf target/linux/airoha/files/drivers/pmdomain/mediatek/Makefile

# 只修改 Airoha target 自己的 kernel config，避免污染其他 target
find target/linux/airoha/ -type f -name "config-*" | while read -r config_file; do
    if grep -q '^CONFIG_AIROHA_CPU_PM_DOMAIN=' "$config_file"; then
        sed -i 's/^CONFIG_AIROHA_CPU_PM_DOMAIN=.*/CONFIG_AIROHA_CPU_PM_DOMAIN=y/' "$config_file"
    else
        echo "CONFIG_AIROHA_CPU_PM_DOMAIN=y" >> "$config_file"
    fi
done
# ------------------------------------------------------------
# 2. 注入 WAN MAC 地址 +1 规则 (uci-defaults 首次启动生效，支持保留配置升级)
# ------------------------------------------------------------

echo ">>> [2/5] 正在配置 WAN MAC 地址 +1 初始化规则..."

# 创建 uci-defaults 目录
mkdir -p files/etc/uci-defaults

cat << 'EOF' > files/etc/uci-defaults/99-fix-wan-mac
#!/bin/sh

# 检查当前 WAN 配置是否存在且设备有效
wan_device=$(uci -q get network.wan.device)
if [ -n "$wan_device" ] && [ -e "/sys/class/net/$wan_device" ]; then
    exit 0
fi

# 未配置或设备无效 → 初始化为 lan1
default_dev="lan1"
if [ ! -e "/sys/class/net/$default_dev" ]; then
    for dev in lan2 lan3 lan4; do
        if [ -e "/sys/class/net/$dev" ]; then
            default_dev="$dev"
            break
        fi
    done
fi
if [ ! -e "/sys/class/net/$default_dev" ]; then
    exit 1
fi

# 计算 MAC +1
mac=$(cat "/sys/class/net/$default_dev/address" 2>/dev/null)
if [ -n "$mac" ] && [ "$mac" != "00:00:00:00:00:00" ]; then
    prefix=$(echo "$mac" | cut -d: -f1-5)
    last=$(printf "%d" 0x$(echo "$mac" | cut -d: -f6))
    new_last=$(( (last + 1) % 256 ))
    new_mac="${prefix}:$(printf "%02x" $new_last)"
fi

proto=$(uci -q get network.wan.proto)
[ -z "$proto" ] && proto="dhcp"

# 配置 WAN 接口
uci set network.wan=interface
uci set network.wan.proto="$proto"
uci set network.wan.device="$default_dev"
[ -n "$new_mac" ] && uci set network.wan.macaddr="$new_mac"

# 设备层 MAC（DSA 架构需要）
uci set network."$default_dev"=device
uci set network."$default_dev".name="$default_dev"
[ -n "$new_mac" ] && uci set network."$default_dev".macaddr="$new_mac"

# ★★★ 关键修复：将该端口从 br-lan 中移除 ★★★
# 优先使用 del_list（适用于 list ports 格式）
if uci -q get network.br-lan.ports >/dev/null 2>&1; then
    uci del_list network.br-lan.ports="$default_dev"
else
    # 兼容旧式 option ports 格式
    current=$(uci get network.br-lan.ports 2>/dev/null)
    if [ -n "$current" ]; then
        new=$(echo "$current" | tr ' ' '\n' | grep -v "^$default_dev$" | tr '\n' ' ' | sed 's/ $//')
        uci set network.br-lan.ports="$new"
    fi
fi

uci commit network
/etc/init.d/network restart

exit 0
EOF
chmod +x files/etc/uci-defaults/99-fix-wan-mac

# ------------------------------------------------------------
# 3. luci-app-airoha-npu：保留上游逻辑，Unknown 时用 dmesg 兜底
#    （Fallback 必须在上游 if/fi 外面，否则 7583 无 npu_fw 时不会执行）
# ------------------------------------------------------------
echo ">>> [3/5] 添加 luci-app-airoha-npu（Unknown 时 dmesg 兜底）..."
rm -rf package/luci-app-airoha-npu
git clone --depth=1 https://github.com/rchen14b/luci-app-airoha-npu.git package/luci-app-airoha-npu
if [ -f package/luci-app-airoha-npu/Makefile ]; then
    sed -i \
        's|include ../../luci.mk|include $(TOPDIR)/feeds/luci/luci.mk|g' \
        package/luci-app-airoha-npu/Makefile
fi

echo "CONFIG_PACKAGE_luci-app-airoha-npu=y" >> .config
echo "CONFIG_PACKAGE_airoha-an7583-npu-firmware=y" >> .config

TARGET_RPC=$(find package/luci-app-airoha-npu -type f -name 'luci.airoha_npu' | head -n1)
if [ -f "$TARGET_RPC" ]; then
  python3 - "$TARGET_RPC" << 'PY' || echo "⚠️ NPU 补丁未匹配，继续编译"
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8", errors="ignore").read()
if "Fallback: dmesg" in text:
    print("already patched")
    sys.exit(0)

old = """\tlocal npu_ver=\"Unknown\"
\tif [ -n \"$npu_fw\" ] && [ -f \"$npu_fw\" ]; then
\t\tnpu_ver=$(strings \"$npu_fw\" 2>/dev/null | grep -oE '([0-9]+\\.[0-9]+\\.[0-9]+-)?TLB[0-9.]+[-_v0-9]*' | head -1)
\t\t[ -z \"$npu_ver\" ] && npu_ver=\"Unknown\"
\tfi
"""

new = """\tlocal npu_ver=\"Unknown\"
\tif [ -n \"$npu_fw\" ] && [ -f \"$npu_fw\" ]; then
\t\tnpu_ver=$(strings \"$npu_fw\" 2>/dev/null | grep -oE '([0-9]+\\.[0-9]+\\.[0-9]+-)?TLB[0-9.]+[-_v0-9]*' | head -1)
\t\t[ -z \"$npu_ver\" ] && npu_ver=\"Unknown\"
\tfi

\t# Fallback: dmesg when upstream yields Unknown (e.g. AN7583 without firmware-name)
\tif [ -z \"$npu_ver\" ] || [ \"$npu_ver\" = \"Unknown\" ]; then
\t\tnpu_ver=$(dmesg 2>/dev/null | grep -i \"NPU fw version\" | tail -n 1 | sed -n \"s/.*NPU fw version: *\\\\([0-9][0-9.]*\\\\).*/\\\\1/p\")
\t\t[ -z \"$npu_ver\" ] && npu_ver=$(logread 2>/dev/null | grep -i \"NPU fw version\" | tail -n 1 | sed -n \"s/.*NPU fw version: *\\\\([0-9][0-9.]*\\\\).*/\\\\1/p\")
\t\t[ -z \"$npu_ver\" ] && npu_ver=\"Unknown\"
\tfi
"""

if old not in text:
    print("ERROR: upstream block not found")
    sys.exit(1)
open(path, "w", encoding="utf-8").write(text.replace(old, new, 1))
print("OK: patched", path)
PY
  echo ">>> 补丁后片段："
  grep -n -A18 'local npu_ver="Unknown"' "$TARGET_RPC" | head -25
else
  echo "⚠️ 未找到 luci.airoha_npu"
fi

# ------------------------------------------------------------
# 4. 集成 KMS 激活服务 (vlmcsd & luci-app-vlmcsd)
# ------------------------------------------------------------
echo ">>> [4/5] 正在添加 vlmcsd KMS 服务..."
rm -rf package/vlmcsd package/luci-app-vlmcsd /tmp/immortal-tmp
mkdir -p /tmp/immortal-tmp

git clone --depth=1 https://github.com/immortalwrt/packages.git /tmp/immortal-tmp/packages
git clone --depth=1 https://github.com/immortalwrt/luci.git /tmp/immortal-tmp/luci

cp -a /tmp/immortal-tmp/packages/net/vlmcsd package/vlmcsd
cp -a /tmp/immortal-tmp/luci/applications/luci-app-vlmcsd package/luci-app-vlmcsd

if [ -f package/luci-app-vlmcsd/Makefile ]; then
    sed -i 's|include ../../luci.mk|include $(TOPDIR)/feeds/luci/luci.mk|' package/luci-app-vlmcsd/Makefile 2>/dev/null || true
fi

rm -rf /tmp/immortal-tmp

# ------------------------------------------------------------
# 5. 清理第三方 Feed 构建冲突，彻底修复 tcping 缺失问题（动态生成标准 OpenWrt 包）
# ------------------------------------------------------------

# ============================================================
# [DIY-P2] 1. 清理 kenzo 与 passwall2 之间的重复冲突包
# ============================================================
echo ">>> [DIY-P2] 正在清理 kenzo 与 passwall2 重复冲突包..."
rm -rf feeds/kenzo/luci-app-passwall* package/feeds/kenzo/luci-app-passwall* 2>/dev/null || true
rm -rf feeds/kenzo/passwall* package/feeds/kenzo/passwall* 2>/dev/null || true
rm -rf feeds/kenzo/chinadns-ng package/feeds/kenzo/chinadns-ng 2>/dev/null || true
rm -rf feeds/kenzo/sing-box package/feeds/kenzo/sing-box 2>/dev/null || true
rm -rf feeds/kenzo/xray-core package/feeds/kenzo/xray-core 2>/dev/null || true
rm -rf feeds/kenzo/tcping package/feeds/kenzo/tcping 2>/dev/null || true

# ============================================================
# [DIY-P2] 2. 导入 Passwall 官方标准的 tcping 包
# ============================================================
echo ">>> [DIY-P2] 正在导入 Passwall 官方 tcping Package..."
rm -rf package/tcping /tmp/pw-pkgs

# 拉取 Passwall 官方 packages 仓库并提取 tcping
git clone --depth=1 https://github.com/openwrt-passwall/openwrt-passwall-packages.git /tmp/pw-pkgs
cp -a /tmp/pw-pkgs/tcping package/tcping
rm -rf /tmp/pw-pkgs

# 解除 Passwall2 Makefile 对 tcping 的硬绑定
sed -i 's/+tcping//g' feeds/passwall2/luci-app-passwall2/Makefile 2>/dev/null || true
sed -i 's/+tcping//g' package/feeds/passwall2/luci-app-passwall2/Makefile 2>/dev/null || true

# ============================================================
# [DIY-P2] 3. 清理坏 Feed 残留，Clone CPU & Temp Status 插件
# ============================================================
echo ">>> [DIY-P2] 正在清理 temp_status 残留并克隆 CPU 与温度插件..."

# 1. 强行抹除 diy-part1 引入的坏 Feed 残留，防止索引报错
rm -rf feeds/temp_status feeds/temp_status.index package/feeds/temp_status 2>/dev/null || true
sed -i '/temp_status/d' feeds.conf feeds.conf.default 2>/dev/null || true

# 2. 直接 Clone 源码到原生 package 目录 (CPU 状态 & 温度状态)
rm -rf package/luci-app-cpu-status package/luci-app-temp-status
git clone --depth=1 https://github.com/gSpotx2f/luci-app-cpu-status.git package/luci-app-cpu-status
git clone --depth=1 https://github.com/gSpotx2f/luci-app-temp-status.git package/luci-app-temp-status

# 3. 注入 MTK/Airoha CPU 温度节点修复补丁 (防止概览卡片漏显温度)
echo ">>> [DIY-P2] 正在修补 LuCI 概览页 CPU 温度读取节点..."
find package/luci-base package/luci-mod-status package/luci-app-cpu-status package/luci-app-temp-status \
    -type f \( -name "*.js" -o -name "*.lua" \) \
    -exec sed -i \
    's|/sys/class/hwmon/hwmon.*/temp1_input|/sys/class/thermal/thermal_zone0/temp|g' {} + \
    2>/dev/null || true

# ============================================================
# [DIY-P2] 4. 重建索引树并安全注入配置
# ============================================================
echo ">>> [DIY-P2] 刷新 package 缓存树与索引..."
rm -rf tmp/.packageinfo tmp/.packageauxvar tmp/.targetinfo

# 写入配置 (tcping、cpu-status、temp-status 及其中文语言包)
cat << 'EOF' >> .config
CONFIG_PACKAGE_tcping=y
CONFIG_PACKAGE_luci-app-cpu-status=y
CONFIG_PACKAGE_luci-i18n-cpu-status-zh-cn=y
CONFIG_PACKAGE_luci-app-temp-status=y
CONFIG_PACKAGE_luci-i18n-temp-status-zh-cn=y
EOF

echo ">>> [DIY-P2] 修复完成！CPU/Temp 插件与温度节点映射均已配置完毕。"

# =========================================================
# 下载 Loyalsoldier 完整规则
# =========================================================
echo ">>> 正在下载 Loyalsoldier 完整规则文件..."

mkdir -p files/usr/share/v2ray

# 只清理本次要覆盖的规则文件
rm -f files/usr/share/v2ray/geosite.dat
rm -f files/usr/share/v2ray/geoip.dat

RULE_OK=1

if ! wget -qO files/usr/share/v2ray/geosite.dat \
    https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat; then
    RULE_OK=0
fi

if ! wget -qO files/usr/share/v2ray/geoip.dat \
    https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat; then
    RULE_OK=0
fi

if [ "$RULE_OK" = "1" ] && \
   [ -s files/usr/share/v2ray/geosite.dat ] && \
   [ -s files/usr/share/v2ray/geoip.dat ]; then

    echo ">>> ✅ Loyalsoldier 规则下载成功"
    echo ">>> geosite.dat:"
    du -h files/usr/share/v2ray/geosite.dat
    echo ">>> geoip.dat:"
    du -h files/usr/share/v2ray/geoip.dat
else
    echo ">>> ⚠️ Loyalsoldier 规则下载失败"
    echo ">>> ⚠️ 不中止编译，将使用官方包提供的规则文件"

    rm -f files/usr/share/v2ray/geosite.dat
    rm -f files/usr/share/v2ray/geoip.dat
fi

echo ">>> 规则文件处理完成"

# =========================================================
# 修正 Airoha PPE debugfs 路径
# =========================================================

echo ">>> [DIY-P2] 修正 Airoha PPE debugfs 路径..."

find package/ -type f \
    \( -name "*.lua" -o -name "*.js" -o -name "*.sh" -o -name "*.c" \) \
    -exec sed -i \
    's|/sys/kernel/debug/ppe0/bind|/sys/kernel/debug/ppe/bind|g' {} + \
    2>/dev/null || true

find package/ -type f \
    \( -name "*.lua" -o -name "*.js" -o -name "*.sh" -o -name "*.c" \) \
    -exec sed -i \
    's|/sys/kernel/debug/ppe0/entries|/sys/kernel/debug/ppe/entries|g' {} + \
    2>/dev/null || true

# ============================================================
# sing-box go依赖错误补丁：钉死 sing-box 版本，避开 Go1.27 + json 编译错误
# 错误：go-json-experiment/json undefined: json.SkipFunc / DiscardUnknownMembers
# 原因：feeds 里 sing-box 1.13.18 与 Go 1.27 默认 jsonv2 不兼容
# 处理：回退到 OpenWrt packages 曾用的 1.12.22
# ============================================================
echo ">>> [DIY-P2] 正在将 sing-box 固定为 1.12.22（修复 Go1.27 编译失败）..."

SINGBOX_MK=""
for p in \
  feeds/packages/net/sing-box/Makefile \
  package/feeds/packages/net/sing-box/Makefile
do
  [ -f "$p" ] && SINGBOX_MK="$p" && break
done

if [ -z "$SINGBOX_MK" ]; then
  echo "⚠️ 未找到 sing-box Makefile，跳过版本固定"
else
  echo ">>> 目标 Makefile: $SINGBOX_MK"

  # 固定版本与官方 tar 包 hash（openwrt/packages 升 1.13.18 前的 1.12.22）
  sed -i 's/^PKG_VERSION:=.*/PKG_VERSION:=1.12.22/' "$SINGBOX_MK"
  sed -i 's/^PKG_RELEASE:=.*/PKG_RELEASE:=1/' "$SINGBOX_MK"
  sed -i 's/^PKG_HASH:=.*/PKG_HASH:=6c4333c3f53a07cc96b63a801fdf6c156820d51cd2eb05e44ea78df290a45377/' "$SINGBOX_MK"

  echo ">>> 修改后版本字段："
  grep -E '^PKG_VERSION|^PKG_RELEASE|^PKG_HASH|^PKG_SOURCE_URL' "$SINGBOX_MK" || true

  # 清掉可能已缓存的 1.13.x / 坏 json 模块，强制按新版本下载
  rm -rf dl/sing-box-1.13.* dl/sing-box-1.12.* 2>/dev/null || true
  rm -rf dl/go-mod-cache/github.com/go-json-experiment 2>/dev/null || true
  rm -rf tmp/go-build 2>/dev/null || true
  rm -rf build_dir/target-*/sing-box-* 2>/dev/null || true

  echo ">>> sing-box 已固定为 1.12.22，并清理相关缓存"
fi

echo ">>> 强制验证硬件加密配置..."

if grep -q '^# CONFIG_KERNEL_CRYPTO_DEV_EIP93 is not set' .config; then
    sed -i \
        's/^# CONFIG_KERNEL_CRYPTO_DEV_EIP93 is not set/CONFIG_KERNEL_CRYPTO_DEV_EIP93=y/' \
        .config
elif grep -q '^CONFIG_KERNEL_CRYPTO_DEV_EIP93=' .config; then
    sed -i \
        's/^CONFIG_KERNEL_CRYPTO_DEV_EIP93=.*/CONFIG_KERNEL_CRYPTO_DEV_EIP93=y/' \
        .config
else
    echo 'CONFIG_KERNEL_CRYPTO_DEV_EIP93=y' >> .config
fi

if grep -q '^CONFIG_KERNEL_CRYPTO_DEV_EIP93=y' .config; then
    echo ">>> ✅ EIP-93 配置已启用"
else
    echo ">>> ⚠️ EIP-93 配置未启用"
fi

# ============================================================
# 临时修复：Airoha AN7583 PPPoE 掉线问题 (Issue #24715)
# 来源：https://github.com/VitaliySochniy/openwrt/commits/airoha-fix-ring-head-refill-race/
# ============================================================
echo ">>> 应用 Airoha AN7583 PPPoE 修复补丁..."

# 进入 OpenWrt 源码目录
#cd openwrt

# 使用 wget 依次下载并应用三个补丁
# 补丁 1: cadfaa6840 - 处理缺失的中断
wget -O - https://github.com/VitaliySochniy/openwrt/commit/cadfaa6840.patch | patch -p1

# 补丁 2: 7f37ab604d - 检测并恢复 ring-4 竞争条件
wget -O - https://github.com/VitaliySochniy/openwrt/commit/7f37ab604d.patch | patch -p1

# 补丁 3: 6518b6179f - 将 ring 4 从 16 增加到 128 个描述符
wget -O - https://github.com/VitaliySochniy/openwrt/commit/6518b6179f.patch | patch -p1

# 返回工作目录
cd $GITHUB_WORKSPACE

echo ">>> Airoha PPPoE 修复补丁已应用"

echo "========================================="
echo ">>> diy-part2.sh 全部执行完毕！"
echo "========================================="
