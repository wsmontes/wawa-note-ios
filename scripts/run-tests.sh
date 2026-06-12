#!/bin/bash
# Wawa Note — Critical Test Runner
# Single build, single xcresult, single DerivedData — no disk bloat.
set -euo pipefail

PROJECT="$(cd "$(dirname "$0")/.." && pwd)/wawa-note.xcodeproj"
SCHEME="wawa-note"
SIM="iPhone 14 Plus"
LOG="/tmp/wawa-test-$(date +%H%M%S).log"

# ── critical: 14 test classes, ~50 tests, < 60s total ─────
CRITICAL="ShellInterpreterTokenizerTests,ImportExportRoundtripTests,SemanticSearchServiceTests,FieldProvenanceTests,FieldAuthorityServiceTests,KnowledgeItemTests,ItemStatusTests,TaskItemTests,IngestionResponseTests,AudioCaptureStateTests,AudioRouteSnapshotTests,AudioRebuildResultTests,RecordingSegmentTests,RecordingManifestIndexProviderTests"

MODE="${1:-critical}"
case "$MODE" in
    critical)
        echo "=== Wawa Note — Critical Tests ($(date +%H:%M:%S)) ==="
        xcrun xcodebuild test \
            -project "$PROJECT" -scheme "$SCHEME" \
            -destination "platform=iOS Simulator,name=$SIM" \
            -only-testing:wawa-noteTests/$CRITICAL \
            2>&1 | tee "$LOG" | grep -E "Test Suite|passed|failed|executed|TEST|error:" | tail -30
        rc=$?
        echo ""
        if [ $rc -eq 0 ]; then
            echo "✅ ALL CRITICAL TESTS PASSED"
        else
            echo "❌ TESTS FAILED — see: $LOG"
            grep -E "Test Case.*failed" "$LOG" | head -20
        fi
        ;;
    all)
        echo "=== Wawa Note — Full Suite ($(date +%H:%M:%S)) ==="
        xcrun xcodebuild test \
            -project "$PROJECT" -scheme "$SCHEME" \
            -destination "platform=iOS Simulator,name=$SIM" \
            -only-testing:wawa-noteTests \
            2>&1 | tee "$LOG" | grep -E "Test Suite|passed|failed|executed|TEST|error:" | tail -30
        ;;
    *)
        echo "Usage: bash scripts/run-tests.sh [critical|all]"
        ;;
esac
