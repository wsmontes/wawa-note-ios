# Wawa Note — Development Makefile
# Zero-intervention build, install, test, log automation.
#
# Quick start:
#   make all        Build → Install → Test
#   make logs       Stream device logs
#   make test       Run tests
#   make install    Install on iPhone 14 Plus

DEVICE_ID  := BBA4F656-A5EA-5D81-934E-E484ED71B8E2
SIM_DEVICE := iPhone 14 Plus
PROJECT    := wawa-note.xcodeproj
SCHEME     := wawa-note
APP_PATH   := $(HOME)/Library/Developer/Xcode/DerivedData/wawa-note-eoznleyektepfbdgabzbwwkbghuq/Build/Products/Debug-iphoneos/Wawa Note.app

.PHONY: all build install logs test clean help

all: build install test  ## Build → Install → Test

build:  ## Build for iPhone 14 Plus (falls back to simulator)
	@echo "🔨 Building..."
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-destination "platform=iOS,id=$(DEVICE_ID)" \
		-configuration Debug build 2>&1 | tail -3

install:  ## Install on iPhone 14 Plus via WiFi/USB
	@echo "📱 Installing..."
	xcrun devicectl device install app --device $(DEVICE_ID) "$(APP_PATH)" 2>&1 \
		| grep -E "App installed|error" || echo "⚠️  Install may have failed"

logs:  ## Stream Wawa Note device logs
	@echo "📋 Streaming logs (Ctrl+C to stop)..."
	@log stream --predicate 'process == "Wawa Note" || eventMessage CONTAINS[c] "wawa" || eventMessage CONTAINS[c] "audio" || eventMessage CONTAINS[c] "pipeline" || eventMessage CONTAINS[c] "agent" || eventMessage CONTAINS[c] "error"' --style compact

test:  ## Run unit tests on simulator
	@echo "🧪 Running tests..."
	xcodebuild test -project $(PROJECT) -scheme $(SCHEME) \
		-destination "platform=iOS Simulator,name=$(SIM_DEVICE)" \
		-only-testing:wawa-noteTests 2>&1 | tail -15

clean:  ## Clean DerivedData
	@echo "🧹 Cleaning..."
	rm -rf $(HOME)/Library/Developer/Xcode/DerivedData/wawa-note-*
	@echo "Done."

deploy: build install  ## Build + install (no tests)

quick:  ## Quick cycle: build + test (no install)
	@echo "⚡ Quick cycle..."
	$(MAKE) build
	$(MAKE) test

help:  ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-12s\033[0m %s\n", $$1, $$2}'
