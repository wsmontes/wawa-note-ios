#!/bin/bash
# Wawa Note — Device Log Capture Pipeline
#
# Real-time streaming (Mac-bridged device logs, no sudo):
#   bash scripts/log-capture.sh stream [14plus|15]
#   bash scripts/log-capture.sh stream 14plus --save
#
# Post-hoc full device collection (requires sudo):
#   bash scripts/log-capture.sh collect 14plus --since 30m
#   bash scripts/log-capture.sh collect 15 --since "2026-06-12 09:00" --crashes --bundle
#
# Quick snapshot:
#   bash scripts/log-capture.sh tail 14plus [N lines]
#
# NOTE: Run with bash, not zsh. In zsh `log` is a builtin that shadows /usr/bin/log.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/device-config.sh"

# ── Predicate Builder ────────────────────────────────────
build_predicate() {
    local mode="${1:-all}"
    # Core: our app's process + relevant event messages
    local base='process == "Wawa Note"'
    base="$base OR eventMessage CONTAINS[c] \"wawa\""
    base="$base OR eventMessage CONTAINS[c] \"audio\""
    base="$base OR eventMessage CONTAINS[c] \"recording\""
    base="$base OR eventMessage CONTAINS[c] \"pipeline\""
    base="$base OR eventMessage CONTAINS[c] \"agent\""
    base="$base OR eventMessage CONTAINS[c] \"transcription\""

    case "$mode" in
        errors)
            echo "$base AND (messageType == error OR messageType == fault)"
            ;;
        all|*)
            echo "$base"
            ;;
    esac
}

# ── Helpers ───────────────────────────────────────────────
timestamp() { date +%Y%m%d-%H%M%S; }
iso_date()  { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
output_path() {
    local device="$1" suffix="${2:-log}"
    mkdir -p "$OUTPUT_DIR"
    echo "$OUTPUT_DIR/wawa-${device}-$(timestamp).${suffix}"
}

# ═══════════════════════════════════════════════════════════
# MODE: stream — Real-time log streaming
# ═══════════════════════════════════════════════════════════
do_stream() {
    local device_alias="${1:-$DEFAULT_DEVICE}"
    local save=false
    shift 2>/dev/null || true
    while [ $# -gt 0 ]; do
        case "$1" in --save) save=true ;; esac
        shift
    done

    resolve_device "$device_alias"

    local predicate
    predicate=$(build_predicate "all")

    echo "═══════════════════════════════════════════════════"
    echo "  📡 Wawa Note — Live Log Stream"
    echo "  Device:  $DEVICE_NAME ($DEVICE_UDID)"
    echo "  iOS:     $DEVICE_IOS"
    echo "  Started: $(date)"
    echo "  Filter:  wawa, audio, recording, pipeline, agent, transcription"
    echo "  Press Ctrl+C to stop."
    echo "═══════════════════════════════════════════════════"
    echo ""

    if $save; then
        local logfile
        logfile=$(output_path "$device_alias" "stream.log")
        echo "  💾 Saving to: $logfile"
        echo ""
        echo "Started: $(iso_date)" > "$logfile"
        echo "Device: $DEVICE_NAME ($DEVICE_UDID) iOS $DEVICE_IOS" >> "$logfile"
        echo "Mode: stream" >> "$logfile"
        echo "---" >> "$logfile"

        log stream --predicate "$predicate" --style compact 2>/dev/null | tee -a "$logfile"
    else
        log stream --predicate "$predicate" --style compact 2>/dev/null
    fi
}

# ═══════════════════════════════════════════════════════════
# MODE: collect — Post-hoc full device log collection
# ═══════════════════════════════════════════════════════════
do_collect() {
    local device_alias="${1:-$DEFAULT_DEVICE}"
    local since="1h"
    local include_crashes=false
    local bundle=false
    shift 2>/dev/null || true
    while [ $# -gt 0 ]; do
        case "$1" in
            --since) since="$2"; shift ;;
            --crashes) include_crashes=true ;;
            --bundle) bundle=true ;;
        esac
        shift
    done

    resolve_device "$device_alias"

    local ts
    ts=$(timestamp)
    local pred_all pred_err
    pred_all=$(build_predicate "all")
    pred_err=$(build_predicate "errors")

    echo ""
    echo "═══════════════════════════════════════════════════"
    echo "  🔍 Wawa Note — Device Log Collection"
    echo "  Device:  $DEVICE_NAME ($DEVICE_UDID)"
    echo "  iOS:     $DEVICE_IOS"
    echo "  Window:  last $since"
    echo "  Started: $(date)"
    echo "═══════════════════════════════════════════════════"
    echo ""

    # ── 1. Collect full logarchive from device ──────────────
    local archive_path
    archive_path=$(output_path "$device_alias" "logarchive")
    echo "  [1/5] Collecting log archive from device..."
    echo "         → $(basename "$archive_path") (10-60s, depends on window)"

    sudo log collect --device-udid "$DEVICE_UDID" \
        --last "$since" \
        --output "$archive_path" \
        2>/dev/null || {
        echo ""
        echo "  ❌ Device log collection requires sudo."
        echo "     Run manually:"
        echo "     sudo log collect --device-udid $DEVICE_UDID --last $since --output ~/Desktop/wawa-logs/"
        echo ""
        echo "  ⏭️  Falling back to Mac-side log show (limited)..."
        echo ""

        # Fallback: Mac-side log show
        local fallback_log
        fallback_log=$(output_path "$device_alias" "mac-fallback.log")
        {
            echo "# Wawa Note — Mac-side Logs (fallback — no device collection)"
            echo "# Device: $DEVICE_NAME ($DEVICE_UDID) iOS $DEVICE_IOS"
            echo "# Window: last $since"
            echo "# Collected: $(iso_date)"
            echo "# Note: These are Mac-side logs only. For full device logs use:"
            echo "#       sudo log collect --device-udid $DEVICE_UDID --last $since"
            echo "#---"
        } > "$fallback_log"
        log show --predicate "$pred_all" --last "$since" --style compact 2>/dev/null >> "$fallback_log" || true

        local fb_lines
        fb_lines=$(wc -l < "$fallback_log" | tr -d ' ')
        echo "  📋 Mac-side log: $(basename "$fallback_log") ($fb_lines lines)"
        echo "  💡 For full device logs, run: sudo log collect --device-udid $DEVICE_UDID --last $since"
        return 0
    }

    local archive_size
    archive_size=$(du -sh "$archive_path" 2>/dev/null | cut -f1)
    echo "         ✅ Archive: $archive_size"

    # ── 2. Extract App Logs ─────────────────────────────────
    local app_log
    app_log=$(output_path "$device_alias" "app.log")
    echo "  [2/5] Extracting app logs → $(basename "$app_log") ..."

    {
        echo "# Wawa Note — App Logs"
        echo "# Device: $DEVICE_NAME ($DEVICE_UDID) iOS $DEVICE_IOS"
        echo "# Window: last $since"
        echo "# Collected: $(iso_date)"
        echo "# Source: $(basename "$archive_path")"
        echo "#---"
    } > "$app_log"

    log show "$archive_path" --predicate "$pred_all" --style compact 2>/dev/null >> "$app_log"
    local app_lines
    app_lines=$(wc -l < "$app_log" | tr -d ' ')
    echo "         $app_lines lines"

    # ── 3. Extract Errors ───────────────────────────────────
    local err_log
    err_log=$(output_path "$device_alias" "errors.log")
    echo "  [3/5] Extracting errors & faults → $(basename "$err_log") ..."

    {
        echo "# Wawa Note — Errors & Faults"
        echo "# Device: $DEVICE_NAME ($DEVICE_UDID) iOS $DEVICE_IOS"
        echo "# Window: last $since"
        echo "# Collected: $(iso_date)"
        echo "#---"
    } > "$err_log"

    log show "$archive_path" --predicate "$pred_err" --style compact 2>/dev/null >> "$err_log"
    local err_lines
    err_lines=$(wc -l < "$err_log" | tr -d ' ')
    if [ "$err_lines" -gt 3 ]; then
        echo "         ⚠️  $err_lines errors/faults — review $(basename "$err_log")"
    else
        echo "         ✅ No errors in window"
    fi

    # ── 4. System Context ──────────────────────────────────
    local sys_log
    sys_log=$(output_path "$device_alias" "system.log")
    echo "  [4/5] Device info + system context → $(basename "$sys_log") ..."

    {
        echo "# Wawa Note — System Context"
        echo "# Device: $DEVICE_NAME ($DEVICE_UDID) iOS $DEVICE_IOS"
        echo "# Collected: $(iso_date)"
        echo ""
        echo "## Device Info"
        xcrun devicectl device info details --device "$DEVICE_UDID" 2>/dev/null || true
        echo ""
        echo "## System Events (kernel, audio, media)"
    } > "$sys_log"

    log show "$archive_path" --predicate '
        (process == "kernel" AND (eventMessage CONTAINS[c] "wawa" OR eventMessage CONTAINS[c] "audio" OR eventMessage CONTAINS[c] "media"))
        OR process == "mediaserverd"
        OR process == "audiod"
    ' --style compact 2>/dev/null >> "$sys_log" || true

    echo "         $(wc -l < "$sys_log" | tr -d ' ') lines"

    # ── 5. Crash Logs (optional) ────────────────────────────
    local crash_log=""
    if $include_crashes; then
        crash_log=$(output_path "$device_alias" "crashes.log")
        echo "  [5/5] Crash analysis → $(basename "$crash_log") ..."

        {
            echo "# Wawa Note — Crash Analysis"
            echo "# Device: $DEVICE_NAME ($DEVICE_UDID) iOS $DEVICE_IOS"
            echo "# Collected: $(iso_date)"
            echo "#---"
            echo ""
            echo "## Local DiagnosticReports (Mac)"
        } > "$crash_log"

        local crash_dir="$HOME/Library/Logs/DiagnosticReports"
        if [ -d "$crash_dir" ]; then
            find "$crash_dir" -name "Wawa*" -mtime -7 -exec echo "--- {} ---" \; -exec cat {} \; >> "$crash_log" 2>/dev/null || true
        fi

        echo "" >> "$crash_log"
        echo "## Device Faults & Termination (logarchive)" >> "$crash_log"
        log show "$archive_path" --predicate 'messageType == fault OR messageType == error' --style compact 2>/dev/null \
            | grep -iE "crash|terminate|kill|jetsam|exc_|assert|fault|panic|signal" >> "$crash_log" 2>/dev/null || true

        echo "         $(wc -l < "$crash_log" | tr -d ' ') lines"
    else
        echo "  [5/5] Skipped (use --crashes)"
    fi

    # ── 6. Bundle (optional) ────────────────────────────────
    if $bundle; then
        local bundle_dir
        bundle_dir="$OUTPUT_DIR/wawa-bug-${device_alias}-${ts}"
        mkdir -p "$bundle_dir"
        cp "$app_log" "$err_log" "$sys_log" "$bundle_dir/"
        cp -R "$archive_path" "$bundle_dir/" 2>/dev/null || true
        [ -n "$crash_log" ] && [ -f "$crash_log" ] && cp "$crash_log" "$bundle_dir/"

        cat > "$bundle_dir/README.md" << README_EOF
# Wawa Note — Bug Report Bundle

- **Device:** $DEVICE_NAME ($DEVICE_MODEL) — iOS $DEVICE_IOS
- **UDID:** $DEVICE_UDID
- **Time window:** last $since
- **Collected:** $(iso_date)

## Contents

| File | Description |
|------|-------------|
| \`app.log\` | All Wawa Note log entries in window |
| \`errors.log\` | Errors and faults only |
| \`system.log\` | Device info + kernel/audio system events |
| \`*.logarchive\` | Raw OSLog archive (open with Console.app) |
README_EOF
        [ -f "$bundle_dir/crashes.log" ] && echo "| \`crashes.log\` | Crash reports + fault analysis |" >> "$bundle_dir/README.md"

        echo ""
        echo "  📦 Bug report bundle: $bundle_dir"
        echo "     $(ls -1 "$bundle_dir" | wc -l | tr -d ' ') files"
        echo "     View archive: open $bundle_dir/*.logarchive"
    fi

    # ── Summary ────────────────────────────────────────────
    echo ""
    echo "═══════════════════════════════════════════════════"
    echo "  Collection complete"
    echo "  App log:    $(basename "$app_log")  ($app_lines lines)"
    echo "  Errors:     $(basename "$err_log")  ($err_lines lines)"
    echo "  Archive:    $(basename "$archive_path")  ($archive_size)"
    echo "  Output:     $OUTPUT_DIR/"
    echo "═══════════════════════════════════════════════════"
}

# ═══════════════════════════════════════════════════════════
# MODE: tail — Quick snapshot
# ═══════════════════════════════════════════════════════════
do_tail() {
    local device_alias="${1:-$DEFAULT_DEVICE}"
    local lines="${2:-100}"

    resolve_device "$device_alias"
    local predicate
    predicate=$(build_predicate "all")

    echo "=== Last $lines Wawa Note entries — $DEVICE_NAME ==="
    log show --predicate "$predicate" --last 5m --style compact 2>/dev/null | tail -"$lines"
}

# ═══════════════════════════════════════════════════════════
# MODE: devices — List configured test devices
# ═══════════════════════════════════════════════════════════
do_devices() {
    echo "=== Wawa Note — Test Devices ==="
    list_devices
    echo ""
    echo "Connected:"
    xcrun xctrace list devices 2>/dev/null | grep -E "iPhone|iPad" | grep -v Simulator | while read -r line; do
        echo "  $line"
    done
}

# ═══════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════
case "${1:-stream}" in
    stream)
        shift
        do_stream "$@"
        ;;
    collect|bug)
        shift
        do_collect "$@"
        ;;
    tail)
        shift
        do_tail "$@"
        ;;
    devices|list)
        do_devices
        ;;
    *)
        echo "Usage: bash scripts/log-capture.sh <mode> [device] [options]"
        echo ""
        echo "Modes:"
        echo "  stream [14plus|15] [--save]      Real-time log streaming (no sudo)"
        echo "  collect [14plus|15] [options]     Full device log collection (sudo)"
        echo "         --since 1h|30m|2h          Time window (default: 1h)"
        echo "         --crashes                  Include crash reports"
        echo "         --bundle                   Package as bug report bundle"
        echo "  tail [14plus|15] [lines]          Quick snapshot (last 5 min)"
        echo "  devices                           List configured test devices"
        echo ""
        echo "Devices: 14plus (default) | 15 | auto"
        echo ""
        echo "Examples:"
        echo "  bash scripts/log-capture.sh stream 14plus --save"
        echo "  bash scripts/log-capture.sh collect 14plus --since 30m --crashes --bundle"
        echo "  bash scripts/log-capture.sh tail 14plus 200"
        echo ""
        list_devices
        ;;
esac
