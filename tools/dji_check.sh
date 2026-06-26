#!/bin/bash
# dji_check.sh — DJI PSDK 运行前检测 + XUDC 自动修复
#
# 用法:
#   ./tools/dji_check.sh          # 检测 + 修复
#   ./tools/dji_check.sh --fix    # 检测 + 强制修复

set -e

UART_DEV="/dev/ttyUSB0"
UDC_NAME="3550000.xudc"
UDC_STATE="/sys/class/udc/${UDC_NAME}/state"
UDC_SPEED="/sys/class/udc/${UDC_NAME}/current_speed"
GADGET_DIR="/sys/kernel/config/usb_gadget/l4t"
BRIDGE="l4tbr0"
BULK_PATHS=(
    "$GADGET_DIR/configs/c.1/ffs.bulk1"
    "$GADGET_DIR/configs/c.1/ffs.bulk2"
)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; }

echo "=== DJI PSDK 环境检测 ==="
echo ""

# --- 1. UART 设备 ---
echo "--- 1. UART 设备 ---"
if [ -e "$UART_DEV" ]; then
    pass "$UART_DEV 存在"
else
    fail "$UART_DEV 不存在 — SkyPort USB-A 线接好了吗？"
fi
echo ""

# --- 2. USB Gadget 状态 ---
echo "--- 2. USB Gadget 状态 ---"
if [ -f "$UDC_STATE" ]; then
    STATE=$(cat "$UDC_STATE" 2>/dev/null || echo "unknown")
    SPEED=$(cat "$UDC_SPEED" 2>/dev/null || echo "unknown")
    echo "  state=$STATE  current_speed=$SPEED"

    if [ "$STATE" = "configured" ]; then
        pass "USB gadget 已配置"
    elif [ "$STATE" = "not attached" ] && [ "$SPEED" = "high-speed" ]; then
        fail "XUDC 卡死 (not attached + high-speed) — 需要修复"
    elif [ "$STATE" = "not attached" ]; then
        warn "USB gadget 未连接 — 无人机上电了？线插好了？"
    else
        warn "未知状态: $STATE"
    fi
else
    fail "UDC 设备 $UDC_NAME 不存在"
fi
echo ""

# --- 3. 网络桥接 ---
echo "--- 3. 网络桥接 ---"
if ip link show "$BRIDGE" &>/dev/null; then
    BR_STATE=$(ip link show "$BRIDGE" | grep -oP 'state \K\w+')
    if [ "$BR_STATE" = "UP" ]; then
        pass "$BRIDGE 状态 UP"
    else
        warn "$BRIDGE 状态 $BR_STATE — 尝试拉起..."
        sudo ip link set "$BRIDGE" up 2>/dev/null && pass "$BRIDGE 已拉起" || fail "$BRIDGE 拉起失败"
    fi
else
    fail "$BRIDGE 不存在"
fi
echo ""

# --- 4. XUDC 修复 ---
XUDC_NEEDS_FIX=false

if [ -f "$UDC_STATE" ]; then
    STATE=$(cat "$UDC_STATE" 2>/dev/null)
    SPEED=$(cat "$UDC_SPEED" 2>/dev/null)
    # 矛盾状态：not attached 但显示 high-speed
    if [ "$STATE" = "not attached" ] && [ "$SPEED" = "high-speed" ]; then
        XUDC_NEEDS_FIX=true
    fi
fi

if [ "$1" = "--fix" ]; then
    XUDC_NEEDS_FIX=true
fi

if $XUDC_NEEDS_FIX; then
    echo "--- 4. 修复 XUDC Gadget ---"

    # 1) 移除旧 ffs 绑定
    for p in "${BULK_PATHS[@]}"; do
        if [ -e "$p" ]; then
            echo "  移除 $p"
            sudo rm -f "$p"
        fi
    done

    # 2) 重置 XUDC 驱动
    echo "  重置 XUDC 驱动..."
    echo "$UDC_NAME" | sudo tee /sys/bus/platform/drivers/tegra-xudc-new/unbind > /dev/null 2>&1 || true
    sleep 2
    echo "$UDC_NAME" | sudo tee /sys/bus/platform/drivers/tegra-xudc-new/bind > /dev/null 2>&1 || true
    sleep 2

    # 3) 绑定 gadget
    if [ -d "$GADGET_DIR" ]; then
        echo "  绑定 UDC..."
        echo "$UDC_NAME" | sudo tee "$GADGET_DIR/UDC" > /dev/null 2>&1 || true
    fi

    # 4) 触发 soft_connect
    if [ -f "$UDC_STATE" ]; then
        echo "  触发 soft_connect..."
        echo "connect" | sudo tee /sys/class/udc/${UDC_NAME}/soft_connect > /dev/null 2>&1 || true
    fi

    sleep 1

    # 验证
    STATE=$(cat "$UDC_STATE" 2>/dev/null || echo "unknown")
    echo "  修复后 state=$STATE"
    if [ "$STATE" = "configured" ]; then
        pass "XUDC 修复成功"
    else
        warn "XUDC 仍为 $STATE，可能需要重新上电无人机"
    fi
else
    echo "--- 4. XUDC 无需修复 ---"
fi

echo ""
echo "=== 检测完成 ==="
echo ""
echo "运行: sudo ./build/bin/dji_sdk_demo_linux_cxx"
echo "菜单: 'c' → '1' (H20T Main Camera)"
