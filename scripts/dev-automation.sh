#!/bin/bash
# Wawa Note — Dev Automation
# Usage: bash scripts/dev-automation.sh [build|install|logs|test|all|clean] [device]
#
# Automates: build → install → log capture → test execution
# on iPhone 14 Plus (default) or iPhone 15 connected via WiFi.
#
# Requirements: Xcode 26+, device paired via devicectl

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/device-config.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $1"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] WARN${NC} $1"; }
err()  { echo -e "${RED}[$(date +%H:%M:%S)] ERROR${NC} $1"; }

# ── build ──────────────────────────────────────────────
do_build() {
    local device_alias="${1:-$DEFAULT_DEVICE}"
    resolve_device "$device_alias"

    log "Building for $DEVICE_NAME (iOS $DEVICE_IOS)..."
    xcodebuild -project "$PROJECT_DIR/wawa-note.xcodeproj" -scheme "$SCHEME" \
        -destination "platform=iOS,id=$DEVICE_UDID" \
        -configuration Debug build 2>&1 | tail -5
    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        log "BUILD SUCCEEDED"
    else
        err "BUILD FAILED — check Xcode for errors"
        return 1
    fi
}

# ── install ────────────────────────────────────────────
do_install() {
    local device_alias="${1:-$DEFAULT_DEVICE}"
    resolve_device "$device_alias"

    # Find latest DerivedData
    local derived
    derived=$(ls -dt $DERIVED_DATA_GLOB 2>/dev/null | head -1)
    local app_path="$derived/Build/Products/Debug-iphoneos/Wawa Note.app"

    if [ ! -d "$app_path" ]; then
        err "App bundle not found: $app_path"
        log "Run 'build' first or check DerivedData"
        return 1
    fi

    log "Installing on $DEVICE_NAME..."
    if xcrun devicectl device install app --device "$DEVICE_UDID" "$app_path" 2>&1; then
        log "INSTALL SUCCEEDED on $DEVICE_NAME"
    else
        warn "WiFi install failed — trying alternate device ID..."
        if xcrun devicectl device install app --device "$DEVICE_HOST" "$app_path" 2>&1; then
            log "INSTALL SUCCEEDED via hostname"
        else
            err "INSTALL FAILED — is the device unlocked and trusted?"
            return 1
        fi
    fi
}

# ── logs ───────────────────────────────────────────────
do_logs() {
    local device_alias="${1:-$DEFAULT_DEVICE}"
    log "Streaming logs for $device_alias (Ctrl+C to stop)..."
    bash "$SCRIPT_DIR/log-capture.sh" stream "$device_alias"
}

# ── test ────────────────────────────────────────────────
do_test() {
    log "Running tests on $SIM_DEVICE_NAME simulator..."
    xcodebuild test -project "$PROJECT_DIR/wawa-note.xcodeproj" -scheme "$SCHEME" \
        -destination "platform=iOS Simulator,name=$SIM_DEVICE_NAME" \
        -only-testing:wawa-noteTests 2>&1 | tail -20
}

# ── all ─────────────────────────────────────────────────
do_all() {
    local device_alias="${1:-$DEFAULT_DEVICE}"
    do_build "$device_alias"
    do_install "$device_alias"
    log "Launch the app manually or: xcrun devicectl device process launch --device $(resolve_device "$device_alias" && echo "$DEVICE_UDID") com.wawa-note"
    do_logs "$device_alias"
}

# ── clean ───────────────────────────────────────────────
do_clean() {
    log "Cleaning DerivedData..."
    rm -rf $DERIVED_DATA_GLOB
    log "Cleaned."
}

# ── main ────────────────────────────────────────────────
ACTION="${1:-all}"
DEVICE_ARG="${2:-$DEFAULT_DEVICE}"

case "$ACTION" in
    build)   do_build "$DEVICE_ARG" ;;
    install) do_install "$DEVICE_ARG" ;;
    logs)    do_logs "$DEVICE_ARG" ;;
    test)    do_test ;;
    all)     do_all "$DEVICE_ARG" ;;
    clean)   do_clean ;;
    *)
        echo "Usage: bash scripts/dev-automation.sh [action] [device]"
        echo ""
        echo "Actions:"
        echo "  build     Build for device"
        echo "  install   Install on device"
        echo "  logs      Stream filtered device logs"
        echo "  test      Run unit tests on simulator"
        echo "  all       Build → Install → Logs"
        echo "  clean     Remove DerivedData"
        echo ""
        echo "Devices:"
        echo "  14plus    iPhone 14 Plus (default, primary tester)"
        echo "  15        iPhone 15"
        echo ""
        echo "Examples:"
        echo "  bash scripts/dev-automation.sh all 14plus"
        echo "  bash scripts/dev-automation.sh build 15"
        ;;
esac
