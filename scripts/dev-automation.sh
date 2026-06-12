#!/bin/bash
# Wawa Note — Dev Automation
# Usage: bash scripts/dev-automation.sh [build|install|logs|test|all]
#
# Automates: build → install → log capture → test execution
# on iPhone 14 Plus connected via USB or WiFi.
#
# Requirements: Xcode 26+, device paired via devicectl

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$PROJECT_DIR/wawa-note.xcodeproj"
SCHEME="wawa-note"
DEVICE_ID="BBA4F656-A5EA-5D81-934E-E484ED71B8E2"
DEVICE_HOST="iPhone.coredevice.local"
APP_PATH="$HOME/Library/Developer/Xcode/DerivedData/wawa-note-eoznleyektepfbdgabzbwwkbghuq/Build/Products/Debug-iphoneos/Wawa Note.app"
SIM_DEVICE="iPhone 14 Plus"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $1"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] WARN${NC} $1"; }
err()  { echo -e "${RED}[$(date +%H:%M:%S)] ERROR${NC} $1"; }

# ── build ──────────────────────────────────────────────
do_build() {
    log "Building for device..."
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
        -destination "platform=iOS,id=$DEVICE_ID" \
        -configuration Debug build 2>&1 | tail -5
    if [ $? -eq 0 ]; then
        log "BUILD SUCCEEDED"
    else
        err "BUILD FAILED — falling back to simulator"
        xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
            -destination "platform=iOS Simulator,name=$SIM_DEVICE" \
            -configuration Debug build 2>&1 | tail -5
    fi
}

# ── install ────────────────────────────────────────────
do_install() {
    log "Installing on iPhone 14 Plus..."
    if [ ! -d "$APP_PATH" ]; then
        err "App bundle not found: $APP_PATH"
        log "Run 'build' first or check DerivedData path"
        return 1
    fi
    # Try WiFi first, fall back to USB
    if xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH" 2>&1; then
        log "INSTALL SUCCEEDED on $DEVICE_HOST"
    else
        warn "WiFi install failed — trying USB..."
        if xcrun devicectl device install app --device "$DEVICE_HOST" "$APP_PATH" 2>&1; then
            log "INSTALL SUCCEEDED via USB"
        else
            err "INSTALL FAILED — is the device unlocked and trusted?"
            return 1
        fi
    fi
}

# ── logs ───────────────────────────────────────────────
do_logs() {
    log "Streaming device logs (Ctrl+C to stop)..."
    log "Filter: wawa, audio, recording, pipeline, agent, error"

    # Try devicectl first (iOS 17+)
    if command -v xcrun &>/dev/null; then
        xcrun devicectl device info dmesg --device "$DEVICE_HOST" 2>/dev/null &
        # Fall back to OSLog stream if devicectl dmesg doesn't work
        xcrun xcdevice log stream --device "$DEVICE_ID" 2>/dev/null &
    fi

    # Also capture system log filtered for our app
    log stream --predicate '
        process == "Wawa Note" OR
        (process == "kernel" AND (eventMessage CONTAINS "wawa" OR eventMessage CONTAINS "audio"))
    ' --style compact 2>/dev/null || warn "log stream requires sudo — run: sudo log stream ..."
}

# ── test ────────────────────────────────────────────────
do_test() {
    log "Running tests on simulator..."
    xcodebuild test -project "$PROJECT" -scheme "$SCHEME" \
        -destination "platform=iOS Simulator,name=$SIM_DEVICE" \
        -only-testing:wawa-noteTests 2>&1 | tail -20
}

# ── all ─────────────────────────────────────────────────
do_all() {
    do_build
    do_install
    log "Launch the app manually or use: xcrun devicectl device process launch --device $DEVICE_HOST com.wawa-note"
    do_logs
}

# ── clean ───────────────────────────────────────────────
do_clean() {
    log "Cleaning DerivedData..."
    rm -rf ~/Library/Developer/Xcode/DerivedData/wawa-note-*
    log "Cleaned."
}

# ── main ────────────────────────────────────────────────
case "${1:-all}" in
    build)   do_build ;;
    install) do_install ;;
    logs)    do_logs ;;
    test)    do_test ;;
    all)     do_all ;;
    clean)   do_clean ;;
    *)
        echo "Usage: bash scripts/dev-automation.sh [build|install|logs|test|all|clean]"
        echo ""
        echo "  build   — Build for iPhone 14 Plus (fallback: simulator)"
        echo "  install — Install on device via WiFi/USB"
        echo "  logs    — Stream device logs (filtered for Wawa Note)"
        echo "  test    — Run unit tests on simulator"
        echo "  all     — Build → Install → Logs"
        echo "  clean   — Remove DerivedData"
        ;;
esac
