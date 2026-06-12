#!/bin/bash
# Wawa Note — Test Runner
# Runs unit tests, captures results, and generates a summary.
# Usage: bash scripts/run-tests.sh [--quick] [--full] [--device]

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$PROJECT_DIR/wawa-note.xcodeproj"
SCHEME="wawa-note"
SIM_DEVICE="iPhone 14 Plus"
DEVICE_ID="${DEVICE_ID:-BBA4F656-A5EA-5D81-934E-E484ED71B8E2}"
RESULT_DIR="$PROJECT_DIR/build/test-results"
mkdir -p "$RESULT_DIR"

MODE="quick"
while [ $# -gt 0 ]; do
    case "$1" in
        --quick) MODE="quick" ;;
        --full)  MODE="full" ;;
        --device) MODE="device" ;;
    esac
    shift
done

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULT_BUNDLE="$RESULT_DIR/Test-$TIMESTAMP.xcresult"
SUMMARY_FILE="$RESULT_DIR/summary-$TIMESTAMP.txt"

echo "=== Wawa Note Test Runner ==="
echo "Mode: $MODE"
echo "Results: $RESULT_BUNDLE"

case "$MODE" in
    quick)
        echo "Running quick tests (core services)..."
        xcodebuild test \
            -project "$PROJECT" \
            -scheme "$SCHEME" \
            -destination "platform=iOS Simulator,name=$SIM_DEVICE" \
            -resultBundlePath "$RESULT_BUNDLE" \
            -only-testing:wawa-noteTests/CoreServicesTests \
            2>&1 | tee "$SUMMARY_FILE"
        ;;
    full)
        echo "Running all tests..."
        xcodebuild test \
            -project "$PROJECT" \
            -scheme "$SCHEME" \
            -destination "platform=iOS Simulator,name=$SIM_DEVICE" \
            -resultBundlePath "$RESULT_BUNDLE" \
            2>&1 | tee "$SUMMARY_FILE"
        ;;
    device)
        echo "Running tests on device..."
        xcodebuild test \
            -project "$PROJECT" \
            -scheme "$SCHEME" \
            -destination "platform=iOS,id=$DEVICE_ID" \
            -resultBundlePath "$RESULT_BUNDLE" \
            -only-testing:wawa-noteTests \
            2>&1 | tee "$SUMMARY_FILE"
        ;;
esac

# Parse results
if grep -q "TEST SUCCEEDED" "$SUMMARY_FILE" 2>/dev/null; then
    echo ""
    echo "✅ ALL TESTS PASSED"
elif grep -q "TEST FAILED" "$SUMMARY_FILE" 2>/dev/null; then
    FAILURES=$(grep -c "failed" "$SUMMARY_FILE" 2>/dev/null || echo "?")
    echo ""
    echo "❌ TESTS FAILED — $FAILURES failure(s)"
    echo "See: $RESULT_BUNDLE"
else
    echo ""
    echo "⚠️  TEST RESULT UNKNOWN — check: $SUMMARY_FILE"
fi
