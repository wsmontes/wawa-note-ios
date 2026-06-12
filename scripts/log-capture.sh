#!/bin/bash
# Wawa Note — Device Log Capture
# Streams iPhone logs to console AND saves to timestamped file.
# Usage: bash scripts/log-capture.sh [--save] [--tail]
#
# Without --save: streams to console only
# With --save: saves to ~/Desktop/wawa-logs-YYYYMMDD-HHMMSS.log
# With --tail: shows last 100 lines and exits

set -euo pipefail

SAVE=false
TAIL=false
OUTPUT_DIR="$HOME/Desktop/wawa-logs"
mkdir -p "$OUTPUT_DIR"

while [ $# -gt 0 ]; do
    case "$1" in
        --save) SAVE=true ;;
        --tail) TAIL=true ;;
    esac
    shift
done

DEVICE_HOST="iPhone.coredevice.local"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOGFILE="$OUTPUT_DIR/wawa-$TIMESTAMP.log"

FILTER='process == "Wawa Note" OR
        eventMessage CONTAINS[c] "wawa" OR
        eventMessage CONTAINS[c] "audio" OR
        eventMessage CONTAINS[c] "recording" OR
        eventMessage CONTAINS[c] "pipeline" OR
        eventMessage CONTAINS[c] "agent" OR
        eventMessage CONTAINS[c] "transcription" OR
        eventMessage CONTAINS[c] "error" OR
        eventMessage CONTAINS[c] "crash"'

if $TAIL; then
    echo "=== Last 100 Wawa Note log entries ==="
    log show --predicate "$FILTER" --last 5m --style compact 2>/dev/null | tail -100
    exit 0
fi

echo "=== Wawa Note Log Capture ==="
echo "Device: $DEVICE_HOST"
echo "Saving to: $LOGFILE"
echo "Filter: wawa, audio, recording, pipeline, agent, transcription, error, crash"
echo "Press Ctrl+C to stop."
echo ""

if $SAVE; then
    echo "Started: $(date)" > "$LOGFILE"
    log stream --predicate "$FILTER" --style compact 2>/dev/null | tee -a "$LOGFILE"
else
    log stream --predicate "$FILTER" --style compact 2>/dev/null
fi
