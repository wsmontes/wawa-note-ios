# Wawa Note — Development Makefile
# Zero-intervention build, install, test, log automation.
#
# Usage examples:
#   make all                                Build → Install → Test (default device)
#   make logs                               Stream logs from iPhone 14 Plus
#   make logs device=15                     Stream logs from iPhone 15
#   make logs-save                          Stream + save to ~/Desktop/wawa-logs/
#   make bug-logs device=14plus since=1h    Collect last hour of logs
#   make bug-report device=14plus since=2h  Full bug report bundle + crashes
#   make tail                               Last 100 lines from default device

SCRIPTS := $(shell cd "$(dir $(lastword $(MAKEFILE_LIST)))" && pwd)/scripts

DEVICE_14PLUS := 00008110-00067D861486201E
DEVICE_15     := 00008120-000260903ED1A01E
DEVICE ?= 14plus
SIM_DEVICE ?= iPhone 14 Plus
PROJECT ?= wawa-note.xcodeproj
SCHEME  ?= wawa-note

# DerivedData varies; find it dynamically
DERIVED_DATA := $(HOME)/Library/Developer/Xcode/DerivedData/wawa-note-eoznleyektepfbdgabzbwwkbghuq
APP_PATH     := $(DERIVED_DATA)/Build/Products/Debug-iphoneos/Wawa Note.app

.PHONY: all build install logs logs-save bug-logs bug-report tail test clean help devices

# ══════════════════════════════════════════════════════════
# Full Cycle
# ══════════════════════════════════════════════════════════

all: build install test  ## Build → Install → Test

# ══════════════════════════════════════════════════════════
# Build & Install
# ══════════════════════════════════════════════════════════

build:  ## Build for device (set DEVICE=15 for iPhone 15)
ifeq ($(DEVICE),15)
	@echo "🔨 Building for iPhone 15..."
	@xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-destination "platform=iOS,id=$(DEVICE_15)" \
		-configuration Debug build 2>&1 | tail -5
else
	@echo "🔨 Building for iPhone 14 Plus..."
	@xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-destination "platform=iOS,id=$(DEVICE_14PLUS)" \
		-configuration Debug build 2>&1 | tail -5
endif

install:  ## Install on device (set DEVICE=15 for iPhone 15)
ifeq ($(DEVICE),15)
	@echo "📱 Installing on iPhone 15..."
	@xcrun devicectl device install app --device $(DEVICE_15) "$(APP_PATH)" 2>&1 \
		| grep -E "App installed|error" || echo "⚠️  Install may have failed"
else
	@echo "📱 Installing on iPhone 14 Plus..."
	@xcrun devicectl device install app --device $(DEVICE_14PLUS) "$(APP_PATH)" 2>&1 \
		| grep -E "App installed|error" || echo "⚠️  Install may have failed"
endif

deploy: build install  ## Build + Install (no tests)

# ══════════════════════════════════════════════════════════
# Log Pipeline
# ══════════════════════════════════════════════════════════

logs:  ## Stream device logs (set DEVICE=15 for iPhone 15)
	@bash $(SCRIPTS)/log-capture.sh stream $(DEVICE)

logs-save:  ## Stream + save to ~/Desktop/wawa-logs/
	@bash $(SCRIPTS)/log-capture.sh stream $(DEVICE) --save

bug-logs:  ## Collect post-hoc logs (set since=1h, DEVICE=14plus, --crashes)
	@bash $(SCRIPTS)/log-capture.sh collect $(DEVICE) --since $(since) $(if $(crashes),--crashes)

bug-report:  ## Full bug report bundle (set since=1h, DEVICE=14plus)
	@bash $(SCRIPTS)/log-capture.sh collect $(DEVICE) --since $(since) --crashes --bundle

tail:  ## Quick last-100 lines snapshot
	@bash $(SCRIPTS)/log-capture.sh tail $(DEVICE) $(if $(lines),$(lines),100)

devices:  ## List configured test devices and connection status
	@bash $(SCRIPTS)/log-capture.sh devices

# ══════════════════════════════════════════════════════════
# Test
# ══════════════════════════════════════════════════════════

test:  ## Run unit tests on simulator
	@echo "🧪 Running tests on $(SIM_DEVICE)..."
	@xcodebuild test -project $(PROJECT) -scheme $(SCHEME) \
		-destination "platform=iOS Simulator,name=$(SIM_DEVICE)" \
		-only-testing:wawa-noteTests 2>&1 | tail -20

quick:  ## Quick cycle: build + test (no install)
	@echo "⚡ Quick cycle..."
	@$(MAKE) build
	@$(MAKE) test

# ══════════════════════════════════════════════════════════
# Cleanup
# ══════════════════════════════════════════════════════════

clean:  ## Clean DerivedData
	@echo "🧹 Cleaning DerivedData..."
	@rm -rf $(HOME)/Library/Developer/Xcode/DerivedData/wawa-note-*
	@echo "Done."

clean-logs:  ## Clean old log files (>7 days)
	@echo "🧹 Cleaning old logs..."
	@find $(HOME)/Desktop/wawa-logs -name "wawa-*" -mtime +7 -delete 2>/dev/null || true
	@echo "Done."

# ══════════════════════════════════════════════════════════
# Help
# ══════════════════════════════════════════════════════════

help:  ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Variables:"
	@echo "  DEVICE=14plus|15    Target device (default: 14plus)"
	@echo "  since=1h|30m|2h    Time window for bug-logs/bug-report"
	@echo "  crashes=1           Include crash reports in bug-logs"
