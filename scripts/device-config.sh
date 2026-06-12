#!/bin/bash
# Wawa Note — Device Configuration
# Single source of truth for all test devices.
# Sourced by other scripts: source scripts/device-config.sh
#
# Usage:
#   source scripts/device-config.sh
#   resolve_device "14plus"   → sets DEVICE_UDID, DEVICE_NAME, DEVICE_HOST, DEVICE_IOS
#   resolve_device "15"       → sets DEVICE_UDID, DEVICE_NAME, DEVICE_HOST, DEVICE_IOS
#   resolve_device "auto"     → picks first connected device

# ── Device Inventory ──────────────────────────────────────
# iPhone 14 Plus — Primary Tester
D14P_UDID="00008110-00067D861486201E"
D14P_NAME="iPhone 14 Plus"
D14P_HOST="iPhone-14-Plus.coredevice.local"
D14P_IOS="18.6.2"
D14P_MODEL="iPhone15,4"

# iPhone 15 — Secondary
D15_UDID="00008120-000260903ED1A01E"
D15_NAME="iPhone 15"
D15_HOST="iPhone-15.coredevice.local"
D15_IOS="26.5"
D15_MODEL="iPhone15,4"

# Default test device
DEFAULT_DEVICE="14plus"

# ── Simulator ─────────────────────────────────────────────
SIM_DEVICE_NAME="iPhone 14 Plus"
SIM_DEVICE_UDID="91BF4C97-F3D6-49D4-9D4A-17BA865D95DE"

# ── Paths ─────────────────────────────────────────────────
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="$HOME/Desktop/wawa-logs"
DERIVED_DATA_GLOB="$HOME/Library/Developer/Xcode/DerivedData/wawa-note-*"

# ── resolve_device <alias> ────────────────────────────────
# Sets: DEVICE_UDID DEVICE_NAME DEVICE_HOST DEVICE_IOS DEVICE_MODEL
resolve_device() {
    local alias="${1:-$DEFAULT_DEVICE}"

    case "$alias" in
        14plus|14|iphone14)
            DEVICE_UDID="$D14P_UDID"
            DEVICE_NAME="$D14P_NAME"
            DEVICE_HOST="$D14P_HOST"
            DEVICE_IOS="$D14P_IOS"
            DEVICE_MODEL="$D14P_MODEL"
            ;;
        15|iphone15)
            DEVICE_UDID="$D15_UDID"
            DEVICE_NAME="$D15_NAME"
            DEVICE_HOST="$D15_HOST"
            DEVICE_IOS="$D15_IOS"
            DEVICE_MODEL="$D15_MODEL"
            ;;
        auto|first)
            # Pick first connected device from xctrace
            local first_udid
            first_udid=$(xcrun xctrace list devices 2>/dev/null | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}' | head -1)
            if [ -z "$first_udid" ]; then
                echo "ERROR: No connected device found" >&2
                return 1
            fi
            DEVICE_UDID="$first_udid"
            DEVICE_NAME="$(xcrun devicectl device info details --device "$first_udid" 2>/dev/null | grep marketingName | awk -F': ' '{print $2}')"
            DEVICE_HOST=""
            DEVICE_IOS=""
            DEVICE_MODEL=""
            ;;
        all|both)
            DEVICE_UDID="all"
            DEVICE_NAME="All Devices"
            DEVICE_HOST=""
            DEVICE_IOS=""
            DEVICE_MODEL=""
            ;;
        *)
            # Assume it's a raw UDID
            DEVICE_UDID="$alias"
            DEVICE_NAME="$(xcrun devicectl device info details --device "$alias" 2>/dev/null | grep marketingName | awk -F': ' '{print $2}')"
            DEVICE_HOST=""
            DEVICE_IOS=""
            DEVICE_MODEL=""
            ;;
    esac
}

# ── list_devices ──────────────────────────────────────────
list_devices() {
    echo "  iPhone 14 Plus  →  $D14P_UDID  (iOS $D14P_IOS)  [PRIMARY TESTER]"
    echo "  iPhone 15       →  $D15_UDID  (iOS $D15_IOS)"
    echo ""
    echo "  Simulator       →  $SIM_DEVICE_NAME  ($SIM_DEVICE_UDID)"
}

# ── is_device_connected <alias> ───────────────────────────
is_device_connected() {
    resolve_device "$1"
    xcrun devicectl device info details --device "$DEVICE_UDID" &>/dev/null
}
