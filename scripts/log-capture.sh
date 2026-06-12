#!/bin/bash
# Wawa Note — Device Log Capture Pipeline
#
# Real-time streaming:
#   bash scripts/log-capture.sh stream [14plus|15|auto|all]
#   bash scripts/log-capture.sh stream 14plus --save
#
# Post-hoc bug investigation:
#   bash scripts/log-capture.sh collect 14plus --since 30m
#   bash scripts/log-capture.sh collect 15 --since "2026-06-12 09:00"
#   bash scripts/log-capture.sh collect 14plus --since 1h --crashes --bundle
#
# Shortcuts (via Makefile):
#   make logs device=14plus              # stream
#   make logs-save device=14plus         # stream + save
#   make bug-logs device=14plus since=1h # post-hoc
#   make bug-report device=14plus since=1h

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/device-config.sh"

# ── OSLog Predicate Builder ───────────────────────────────
# Builds Apple unified logging predicate for our app.
# Levels: Debug, Info, Default, Error, Fault
# Subsystems: com.wawa-note.* (set in app's Logger definitions)

build_predicate() {
    local level="${1:-all}"
    local base='process == "Wawa Note"'

    # Always capture our app's log messages plus relevant system events
    base="$base OR (senderImagePath CONTAINS \"Wawa\")"
    base="$base OR (eventMessage CONTAINS[c] \"wawa\")"

    case "$level" in
        errors)
            echo "$base AND (messageType == error OR messageType == fault)"
            ;;
        errors+warnings)
            echo "$base AND messageType != debug AND messageType != info"
            ;;
        verbose)
            echo "$base"
            ;;
        all|*)
            echo "$base"
            ;;
    esac
}

# ── Timestamp Helpers ─────────────────────────────────────
timestamp() { date +%Y%m%d-%H%M%S; }
iso_date()  { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# ── Output Path ───────────────────────────────────────────
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
    echo "  Filter:  Wawa Note + audio + pipeline + agent + errors"
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

        log stream --predicate "$predicate" --style compact 2>/dev/null \
            | tee -a "$logfile"
    else
        log stream --predicate "$predicate" --style compact 2>/dev/null
    fi
}

# ═══════════════════════════════════════════════════════════
# MODE: collect — Post-hoc log collection (bug investigation)
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
    local pred_default pred_errors
    pred_default=$(build_predicate "all")
    pred_errors=$(build_predicate "errors")

    echo ""
    echo "═══════════════════════════════════════════════════"
    echo "  🔍 Wawa Note — Log Collection"
    echo "  Device:  $DEVICE_NAME ($DEVICE_UDID)"
    echo "  iOS:     $DEVICE_IOS"
    echo "  Window:  last $since"
    echo "  Started: $(date)"
    echo "═══════════════════════════════════════════════════"
    echo ""

    # ── 1. App Logs ───────────────────────────────────────
    local app_log
    app_log=$(output_path "$device_alias" "app.log")
    echo "  [1/4] Collecting app logs → $(basename "$app_log") ..."

    {
        echo "# Wawa Note — App Logs"
        echo "# Device: $DEVICE_NAME ($DEVICE_UDID) iOS $DEVICE_IOS"
        echo "# Window: last $since"
        echo "# Collected: $(iso_date)"
        echo "#---"
    } > "$app_log"

    log show --predicate "$pred_default" --last "$since" --style compact 2>/dev/null >> "$app_log"
    local app_lines
    app_lines=$(wc -l < "$app_log" | tr -d ' ')
    echo "         $app_lines lines captured"

    # ── 2. Errors & Faults ────────────────────────────────
    local err_log
    err_log=$(output_path "$device_alias" "errors.log")
    echo "  [2/4] Collecting errors & faults → $(basename "$err_log") ..."

    {
        echo "# Wawa Note — Errors & Faults"
        echo "# Device: $DEVICE_NAME ($DEVICE_UDID) iOS $DEVICE_IOS"
        echo "# Window: last $since"
        echo "# Collected: $(iso_date)"
        echo "#---"
    } > "$err_log"

    log show --predicate "$pred_errors" --last "$since" --style compact 2>/dev/null >> "$err_log"
    local err_lines
    err_lines=$(wc -l < "$err_log" | tr -d ' ')
    if [ "$err_lines" -gt 2 ]; then
        echo "         ⚠️  $err_lines errors found — review $(basename "$err_log")"
    else
        echo "         ✅ No errors in window"
    fi

    # ── 3. System Context ──────────────────────────────────
    local sys_log
    sys_log=$(output_path "$device_alias" "system.log")
    echo "  [3/4] Collecting system context → $(basename "$sys_log") ..."

    {
        echo "# Wawa Note — System Context"
        echo "# Device: $DEVICE_NAME ($DEVICE_UDID) iOS $DEVICE_IOS"
        echo "# Collected: $(iso_date)"
    } > "$sys_log"

    # Device info
    echo "" >> "$sys_log"
    echo "## Device Info" >> "$sys_log"
    xcrun devicectl device info details --device "$DEVICE_UDID" 2>/dev/null >> "$sys_log" || true

    # Recent system events around our app
    echo "" >> "$sys_log"
    echo "## System Events (kernel, mediaserverd, audio)" >> "$sys_log"
    log show --predicate '
        (process == "kernel" AND (eventMessage CONTAINS[c] "wawa" OR eventMessage CONTAINS[c] "audio" OR eventMessage CONTAINS[c] "media"))
        OR process == "mediaserverd"
        OR process == "audio"
    ' --last "$since" --style compact 2>/dev/null >> "$sys_log" || true

    echo "         $(wc -l < "$sys_log" | tr -d ' ') lines"

    # ── 4. Crash Logs (optional) ──────────────────────────
    if $include_crashes; then
        local crash_log
        crash_log=$(output_path "$device_alias" "crashes.log")
        echo "  [4/4] Collecting crash logs → $(basename "$crash_log") ..."

        {
            echo "# Wawa Note — Crash Reports"
            echo "# Device: $DEVICE_NAME ($DEVICE_UDID) iOS $DEVICE_IOS"
            echo "# Collected: $(iso_date)"
            echo "#---"
        } > "$crash_log"

        # Recent crashes from local crash reporter
        local crash_dir="$HOME/Library/Logs/DiagnosticReports"
        if [ -d "$crash_dir" ]; then
            find "$crash_dir" -name "Wawa*" -mtime -7 -exec echo "--- {} ---" \; -exec cat {} \; >> "$crash_log" 2>/dev/null || true
        fi

        echo "         $(wc -l < "$crash_log" | tr -d ' ') lines"
    else
        echo "  [4/4] Skipped (use --crashes to include)"
    fi

    # ── 5. Bundle (optional) ───────────────────────────────
    if $bundle; then
        local bundle_dir
        bundle_dir="$OUTPUT_DIR/wawa-bug-${device_alias}-${ts}"
        mkdir -p "$bundle_dir"
        cp "$app_log" "$err_log" "$sys_log" "$bundle_dir/"
        [ -f "$crash_log" ] && cp "$crash_log" "$bundle_dir/"

        # Add README
        cat > "$bundle_dir/README.md" << EOF
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
EOF
        [ -f "$bundle_dir/crashes.log" ] && echo "| \`crashes.log\` | Crash reports (7-day window) |" >> "$bundle_dir/README.md"

        echo ""
        echo "  📦 Bug report bundle: $bundle_dir"
        echo "     $(ls -1 "$bundle_dir" | wc -l | tr -d ' ') files ready"
    fi

    # ── Summary ───────────────────────────────────────────
    echo ""
    echo "═══════════════════════════════════════════════════"
    echo "  Collection complete"
    echo "  App log:    $(basename "$app_log")  ($app_lines lines)"
    echo "  Errors:     $(basename "$err_log")  ($err_lines lines)"
    echo "  Output:     $OUTPUT_DIR/"
    echo "═══════════════════════════════════════════════════"
}

# ═══════════════════════════════════════════════════════════
# MODE: tail — Quick last-N lines snapshot
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
        echo "  stream [14plus|15|auto] [--save]   Real-time log streaming"
        echo "  collect [14plus|15] [--since 1h]   Post-hoc log collection"
        echo "           [--crashes] [--bundle]      + crash reports, bundle as bug report"
        echo "  tail [14plus|15] [lines]           Quick last-N snapshot"
        echo "  devices                             List test devices"
        echo ""
        echo "Devices:"
        echo "  14plus   iPhone 14 Plus (default, primary tester)"
        echo "  15       iPhone 15"
        echo "  auto     Auto-detect first connected"
        echo "  all      All connected devices"
        echo ""
        echo "Examples:"
        echo "  bash scripts/log-capture.sh stream 14plus --save"
        echo "  bash scripts/log-capture.sh collect 14plus --since 30m --crashes --bundle"
        echo "  bash scripts/log-capture.sh collect 15 --since \"2026-06-12 09:00\""
        echo ""
        list_devices
        ;;
esac
