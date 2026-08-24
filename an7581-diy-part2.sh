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

# 2. 同步开启 target 层级的内核配置宏，让原生 221-02 Patch 的驱动生效
find target/linux/airoha/ -name "config-*" | while read -r config_file; do
    grep -q "CONFIG_AIROHA_CPU_PM_DOMAIN" "$config_file" || echo "CONFIG_AIROHA_CPU_PM_DOMAIN=y" >> "$config_file"
done

# ------------------------------------------------------------
# 2. 注入 WAN MAC 地址 +1 规则 (uci-defaults 首次启动生效，支持保留配置升级)
# ------------------------------------------------------------
echo ">>> [2/5] 正在配置 WAN MAC 地址 +1 初始化规则..."

# 创建 uci-defaults 目录
mkdir -p files/etc/uci-defaults

echo ">>> [2/5] 正在配置 WAN MAC 地址 +1 初始化规则..."

# 创建 uci-defaults 目录
mkdir -p files/etc/uci-defaults

cat << 'EOF' > files/etc/uci-defaults/99-fix-wan-mac
#!/bin/sh

# 1. 安全检查：如果检测到已有网络配置（说明是保留配置升级上来的），直接退出不干预
if uci -q get network.wan.proto >/dev/null; then
    exit 0
fi

# 2. 抓取 lan1 节点的原始物理 MAC
lan_mac=$(cat /sys/class/net/lan1/address 2>/dev/null)

if [ -n "$lan_mac" ] && [ "$lan_mac" != "00:00:00:00:00:00" ]; then
    prefix=$(echo "$lan_mac" | awk -F: '{print $1":"$2":"$3":"$4":"$5}')
    last_hex=$(echo "$lan_mac" | awk -F: '{print $6}')
    
    last_dec=$(printf "%d" "0x$last_hex")
    next_dec=$(( (last_dec + 1) % 256 ))
    next_hex=$(printf "%02x" $next_dec)
    wan_mac="${prefix}:${next_hex}"

    # 3. 将 WAN 口正确绑定到物理网卡 lan1
    uci set network.wan=interface
    uci set network.wan.proto='dhcp'
    uci set network.wan.device='lan1'
    uci set network.wan.macaddr="$wan_mac"

    # 4. 将 MAC 注入物理 lan1 设备层 (DSA 架构)
    uci set network.lan1=device
    uci set network.lan1.name='lan1'
    uci set network.lan1.macaddr="$wan_mac"

    uci commit network
fi

exit 0
EOF

# 赋予可执行权限
chmod +x files/etc/uci-defaults/99-fix-wan-mac


# ------------------------------------------------------------
# 3. 集成 Airoha NPU 控制插件 (luci-app-airoha-npu)
# ------------------------------------------------------------
echo ">>> [3/5] 正在添加 luci-app-airoha-npu 插件并修补 NPU 版本提取逻辑..."
rm -rf package/luci-app-airoha-npu
git clone --depth=1 https://github.com/rchen14b/luci-app-airoha-npu.git package/luci-app-airoha-npu
sed -i 's|include ../../luci.mk|include $(TOPDIR)/feeds/luci/luci.mk|' package/luci-app-airoha-npu/Makefile

# 强行开启配置选中
echo "CONFIG_PACKAGE_luci-app-airoha-npu=y" >> .config

# 修补 rpcd 后端脚本
TARGET_RPC=$(find package/luci-app-airoha-npu/ -name "luci.airoha_npu" 2>/dev/null | head -n 1)

if [ -n "$TARGET_RPC" ] && [ -f "$TARGET_RPC" ]; then
    echo ">>> 正在修补 RPC 目标文件: $TARGET_RPC"
    sed -i '/strings "$npu_fw"/c\                npu_ver=$(dmesg | grep -i "NPU fw version" | tail -n 1 | sed -n "s/.*NPU fw version: *\\([0-9.]*\\).*/\\1/p")' "$TARGET_RPC"
    sed -i 's/"Unknown"/"1456.62"/g' "$TARGET_RPC"
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
find package/ -type f \( -name "luci" -o -name "10_system.js" \) -exec sed -i 's|/sys/class/hwmon/hwmon.*/temp1_input|/sys/class/thermal/thermal_zone0/temp|g' {} + 2>/dev/null || true

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
# 自动拉取 Loyalsoldier 最新 geosite/geoip 规则并注入固件
# =========================================================
echo ">>> 正在从 github.com/Loyalsoldier 下载最新的 geosite / geoip 数据库..."

# 1. 清理并重新创建唯一需要的 v2ray 目标文件夹
rm -rf files/usr/share/xray files/usr/share/v2ray
mkdir -p files/usr/share/v2ray/

# 2. 从 github 下载最新数据库直接存入 v2ray 目录
wget -qO files/usr/share/v2ray/geosite.dat https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat
wget -qO files/usr/share/v2ray/geoip.dat https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat

echo ">>> 最新 geosite / geoip 数据库注入完成！"

# 强制关闭 SS-Rust，避免 aarch64 默认带上 rust/host
for opt in \
  luci-app-passwall2_INCLUDE_Shadowsocks_Rust_Client \
  luci-app-passwall2_INCLUDE_Shadowsocks_Rust_Server \
  shadowsocks-rust-sslocal \
  shadowsocks-rust-ssserver \
  shadowsocks-rust-ssmanager \
  shadowsocks-rust-ssurl \
  shadowsocks-rust-ssservice
do
  sed -i "/CONFIG_PACKAGE_${opt}/d" .config 2>/dev/null || true
  echo "# CONFIG_PACKAGE_${opt} is not set" >> .config
done
sed -i '/CONFIG_USE_EXTERNAL_HOST_RUST/d' .config 2>/dev/null || true
echo "# CONFIG_USE_EXTERNAL_HOST_RUST is not set" >> .config

# =========================================================
# 修正 Airoha PPE debugfs 路径匹配 (加在文件最末尾)
# =========================================================
find package/ -type f \( -name "*.lua" -o -name "*.js" -o -name "*.sh" -o -name "*.c" \) \
    -exec sed -i 's/\/sys\/kernel\/debug\/ppe0\/bind/\/sys\/kernel\/debug\/ppe\/bind/g' {} +

find package/ -type f \( -name "*.lua" -o -name "*.js" -o -name "*.sh" -o -name "*.c" \) \
    -exec sed -i 's/\/sys\/kernel\/debug\/ppe0\/entries/\/sys\/kernel\/debug\/ppe\/entries/g' {} +
    
echo "========================================="
echo ">>> diy-part2.sh 全部执行完毕！"
echo "========================================="
