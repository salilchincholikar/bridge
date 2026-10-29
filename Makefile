# bridge: common tasks. Run `make help`. Modeled on ../waffle's Makefile.
.PHONY: help app run test clean demo demo-app ui-test ui-test-app lint example verify-bundle check

SWIFT_FLAGS ?=
.NOTPARALLEL:

help:       ## Show this help
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-8s %s\n", $$1, $$2}'

app:        ## Build build/Bridge.app (release)
	@BRIDGE_SWIFT_FLAGS="$(SWIFT_FLAGS)" scripts/bundle.sh release

run: app    ## Build and launch the app
	@open build/Bridge.app

test:       ## Run the BridgeCore tests (plain executable; no XCTest needed)
	@swift build $(SWIFT_FLAGS) -c release --product BridgeApp
	@swift run $(SWIFT_FLAGS) -c release BridgeCoreTests

example:    ## Run the independent Core client example (in-memory, no AWS)
	@swift run $(SWIFT_FLAGS) -c release BridgeClientExample

lint:       ## Validate curated JSON/plist assets and shell syntax
	@python3 scripts/check-source.py
	@for script in scripts/*.sh; do sh -n "$$script"; done

verify-bundle: ## Verify an already-built production app has no demo fixtures or UI test entry point
	@sh scripts/verify-bundle.sh

check: lint test example app verify-bundle ## Run local checks (GUI acceptance is separate)

demo-app:   ## Build a Finder-launchable app with invented AWS data
	@BRIDGE_SWIFT_FLAGS="$(SWIFT_FLAGS)" scripts/bundle.sh release demo

demo: demo-app ## Run the demo bundle (invented AWS data and fake provider executables)
	@'build/Bridge Demo.app/Contents/MacOS/Bridge'

ui-test-app: ## Build Finder-launchable offline UI checks; logs and snapshots go to /private/tmp
	@BRIDGE_SWIFT_FLAGS="$(SWIFT_FLAGS)" scripts/ui-test-app.sh

ui-test: ui-test-app ## Check the real UI in a macOS GUI session using the dedicated offline test bundle
	@BRIDGE_UI_SELFTEST=1 'build/Bridge UI Checks.app/Contents/MacOS/Bridge'

clean:      ## Remove build outputs
	rm -rf build .build
