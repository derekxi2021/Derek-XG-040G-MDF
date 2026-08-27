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

echo ">>> 启用 DTS crypto 节点..."
for DTS_FILE in $(find target/linux/airoha/dts -type f \( -name '*7581*' -o -name '*en7581*' -o -name 'an7581*' \) 2>/dev/null); do
  [ -f "$DTS_FILE" ] || continue
  if grep -qE 'crypto@|&crypto' "$DTS_FILE"; then
    sed -i '/crypto@\|&crypto/,/^[[:space:]]*};/ s/status = "disabled";/status = "okay";/' "$DTS_FILE"
    echo ">>> 已处理 $DTS_FILE"
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
# 3. 集成 Airoha NPU 控制插件 (luci-app-airoha-npu)
# ------------------------------------------------------------
echo ">>> [3/5] 正在添加 luci-app-airoha-npu 插件并修补 NPU 版本提取逻辑..."
rm -rf package/luci-app-airoha-npu
git clone --depth=1 https://github.com/rchen14b/luci-app-airoha-npu.git package/luci-app-airoha-npu
sed -i 's|include ../../luci.mk|include $(TOPDIR)/feeds/luci/luci.mk|' package/luci-app-airoha-npu/Makefile

# 强制开启配置选中
echo "CONFIG_PACKAGE_luci-app-airoha-npu=y" >> .config

# ------------------------------------------------------------
# 修补 rpcd 后端脚本：彻底替换 NPU 版本提取逻辑（从 dmesg 直接提取）
# ------------------------------------------------------------
TARGET_RPC=$(find package/luci-app-airoha-npu/ -name "luci.airoha_npu" 2>/dev/null | head -n 1)
if [ -n "$TARGET_RPC" ] && [ -f "$TARGET_RPC" ]; then
    echo ">>> 正在彻底替换 RPC 目标文件中的 NPU 版本提取逻辑: $TARGET_RPC"

    # 使用 awk 替换整个 npu_ver 赋值和后续 if 块（与你在设备上手动测试成功的逻辑完全一致）
    awk -i inplace '
    /^[[:space:]]*local npu_ver="Unknown"/ {
        print "    local npu_ver=\"\""
        print "    npu_ver=$(dmesg 2>/dev/null | grep -i \"NPU fw version\" | tail -n 1 | sed -n \"s/.*NPU fw version: *\\([0-9][0-9.]*\\).*/\\1/p\")"
        print "    [ -z \"$npu_ver\" ] && npu_ver=\"Unknown\""
        # 跳过整个 if 块（直到匹配到 fi）
        in_if_block = 1
        next
    }
    in_if_block && /^[[:space:]]*fi/ {
        in_if_block = 0
        next
    }
    in_if_block { next }
    { print }
    ' "$TARGET_RPC"

    # 如果 awk -i inplace 不支持，使用临时文件方式（备用）
    if [ $? -ne 0 ]; then
        echo ">>> awk -i inplace 不支持，改用临时文件..."
        awk '
        /^[[:space:]]*local npu_ver="Unknown"/ {
            print "    local npu_ver=\"\""
            print "    npu_ver=$(dmesg 2>/dev/null | grep -i \"NPU fw version\" | tail -n 1 | sed -n \"s/.*NPU fw version: *\\([0-9][0-9.]*\\).*/\\1/p\")"
            print "    [ -z \"$npu_ver\" ] && npu_ver=\"Unknown\""
            in_if_block = 1
            next
        }
        in_if_block && /^[[:space:]]*fi/ {
            in_if_block = 0
            next
        }
        in_if_block { next }
        { print }
        ' "$TARGET_RPC" > "$TARGET_RPC.tmp" && mv "$TARGET_RPC.tmp" "$TARGET_RPC"
    fi

    echo ">>> NPU 版本提取逻辑已彻底替换"
else
    echo "⚠️ 未找到 luci.airoha_npu 文件，跳过修补"
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
# 硬件加密：EIP-93（直接写入 CONFIG_*）
# =========================================================
echo ">>> 配置 EIP-93 硬件加密..."

# 1) 尝试写入 target/linux/airoha/config-*（如果存在）
KERNEL_CONFIG=$(find target/linux/airoha -maxdepth 1 -name 'config-*' | head -n1)
if [ -n "$KERNEL_CONFIG" ] && [ -f "$KERNEL_CONFIG" ]; then
  echo ">>> 写入内核片段: $KERNEL_CONFIG"
  for opt in \
    CONFIG_CRYPTO_HW \
    CONFIG_CRYPTO_ENGINE \
    CONFIG_CRYPTO_DEV_EIP93 \
    CONFIG_CRYPTO_DEV_EIP93_AES \
    CONFIG_CRYPTO_DEV_EIP93_DES \
    CONFIG_CRYPTO_AES_ARM64_NEON_BLK
  do
    sed -i "/^${opt}=/d;/^# ${opt} is not set/d" "$KERNEL_CONFIG"
    echo "${opt}=y" >> "$KERNEL_CONFIG"
  done
else
  echo "⚠️ 未找到内核配置片段，将只修改 .config"
fi

# 2) .config 直接写 CONFIG_*（主要手段）
for opt in \
  CONFIG_CRYPTO_HW \
  CONFIG_CRYPTO_ENGINE \
  CONFIG_CRYPTO_DEV_EIP93 \
  CONFIG_CRYPTO_DEV_EIP93_AES \
  CONFIG_CRYPTO_DEV_EIP93_DES \
  CONFIG_CRYPTO_AES_ARM64_NEON_BLK
do
  sed -i "/^${opt}=/d;/^# ${opt} is not set/d" .config
  echo "${opt}=y" >> .config
done

# 3) 关闭无效的 CE 选项
for opt in \
  CONFIG_CRYPTO_AES_ARM64_CE \
  CONFIG_CRYPTO_AES_ARM64_CE_BLK \
  CONFIG_CRYPTO_AES_ARM64_CE_CCM
do
  sed -i "/^${opt}/d" .config
  echo "# ${opt} is not set" >> .config
done

# 4) 用户态包
for pkg in PACKAGE_kmod-cryptodev PACKAGE_libopenssl-devcrypto PACKAGE_openssl-util; do
  sed -i "/CONFIG_${pkg}/d" .config
  echo "CONFIG_${pkg}=y" >> .config
done

echo ">>> EIP-93 配置写入完成"

# =========================================================
# 下载 Loyalsoldier 完整规则（覆盖官方包，保留编译依赖）
# =========================================================
echo ">>> 正在下载 Loyalsoldier 完整规则文件..."

# 注意：不删除/禁用 CONFIG_PACKAGE_v2ray-geoip 和 v2ray-geosite
# 因为 sing-box 和 xray 编译时需要它们作为依赖
# 但运行时，我们的 files/ 目录会覆盖官方规则文件

# 1. 清理旧目录并创建新目录
rm -rf files/usr/share/xray files/usr/share/v2ray
mkdir -p files/usr/share/v2ray/
mkdir -p files/usr/share/xray

# 2. 下载 Loyalsoldier 规则（比官方更全）
wget -qO files/usr/share/v2ray/geosite.dat https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat
wget -qO files/usr/share/v2ray/geoip.dat https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat

# 3. 为 xray 创建软链接（同一份文件供两个工具使用）
ln -sf ../v2ray/geosite.dat files/usr/share/xray/geosite.dat 2>/dev/null || true
ln -sf ../v2ray/geoip.dat files/usr/share/xray/geoip.dat 2>/dev/null || true

# 4. 验证下载
if [ -f files/usr/share/v2ray/geosite.dat ] && [ -f files/usr/share/v2ray/geoip.dat ]; then
    echo ">>> ✅ 规则文件下载成功，文件大小："
    du -sh files/usr/share/v2ray/*.dat
else
    echo "⚠️ 警告：规则文件下载失败，请检查网络！"
    echo ">>> 将使用官方包自带的规则文件作为备选"
fi

echo ">>> 规则文件注入完成"

# =========================================================
# 修正 Airoha PPE debugfs 路径匹配
# =========================================================
find package/ -type f \( -name "*.lua" -o -name "*.js" -o -name "*.sh" -o -name "*.c" \) \
    -exec sed -i 's/\/sys\/kernel\/debug\/ppe0\/bind/\/sys\/kernel\/debug\/ppe\/bind/g' {} +

find package/ -type f \( -name "*.lua" -o -name "*.js" -o -name "*.sh" -o -name "*.c" \) \
    -exec sed -i 's/\/sys\/kernel\/debug\/ppe0\/entries/\/sys\/kernel\/debug\/ppe\/entries/g' {} +

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

# 强制在 .config 中启用 EIP-93 及其依赖（确保 defconfig 不会完全抹掉）
for opt in CONFIG_CRYPTO_ENGINE CONFIG_CRYPTO_DEV_EIP93 CONFIG_CRYPTO_DEV_EIP93_DEBUG CONFIG_CRYPTO_AES_ARM64_NEON_BLK; do
    sed -i "/^${opt}/d" .config
    echo "${opt}=y" >> .config
done

echo "========================================="
echo ">>> diy-part2.sh 全部执行完毕！"
echo "========================================="
