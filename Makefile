.DEFAULT_GOAL := help

PACKAGE_OUTPUT ?= build/package-$(shell /usr/bin/uuidgen)
SMOKE_OUTPUT ?= build/smoke-$(shell /usr/bin/uuidgen)
SMOKE_OUTPUT := $(SMOKE_OUTPUT)
SWIFT_SOURCES := Package.swift App/Sources Packages/CopilotMicroKit/Package.swift Packages/CopilotMicroKit/Sources Packages/CopilotMicroKit/Tests

.PHONY: help doctor doctor-xcode build package smoke-test test-doctor test-packager test-contracts test-bridge test-cli-probe test-core qualify-cli qualify-terminals qualify-ghostty qualify-ghostty-roundtrip qualify-hardware observe-device-input qualify-device-lighting preview-device-mapping apply-device-mapping preview-device-restore restore-device-mapping lint format check

help:
	@printf '%s\n' \
		'doctor-xcode  Check the optional full-Xcode environment without changing settings' \
		'doctor        Check local Swift/macOS SDK prerequisites with CLT or Xcode' \
		'build         Compile the native arm64 app with SwiftPM' \
		'package       Build and ad-hoc sign an app in a fresh build/package-* directory' \
		'smoke-test    Verify hidden UI/resources and accessory lifecycle, then clean output' \
		'test-doctor   Run isolated prerequisite-checker tests' \
		'test-packager Run isolated packaging safety tests' \
		'test-contracts Validate shared native/bridge schemas, catalogs and fixtures' \
		'test-bridge  Run isolated Node IPC protocol and client tests' \
		'test-cli-probe Run disposable CLI probe staging and evidence tests' \
		'test-core     Run the Core package Swift Testing suite without XCTest' \
		'qualify-cli   Explicitly launch an owned disposable CLI capability probe' \
		'qualify-terminals Read supported terminal and Copilot CLI installation metadata' \
		'qualify-ghostty Read exact Ghostty window, tab and terminal IDs with consent' \
		'qualify-ghostty-roundtrip Create, focus and close temporary Ghostty surfaces' \
		'qualify-hardware Run the read-only Creator Micro 2 hardware probe with exact consent' \
		'observe-device-input Print normalized physical input for a bounded interval' \
		'qualify-device-lighting Run a bounded all-key color sequence without changing underglow or flash' \
		'preview-device-mapping Save/verify the original backup and print the exact non-mutating mapping plan' \
		'apply-device-mapping Apply one reviewed mapping plan, then verify read-back' \
		'preview-device-restore Print the exact non-mutating original-map restore plan' \
		'restore-device-mapping Restore one reviewed original backup, then verify read-back' \
		'lint          Check JavaScript syntax and Swift formatting' \
		'format        Apply the repository Swift formatting configuration' \
		'check         Run local tooling, Core and headless native checks; no live integrations'

doctor:
	node scripts/doctor.mjs

doctor-xcode:
	node scripts/doctor.mjs --phase xcode

build:
	./scripts/swiftpm build --arch arm64 --scratch-path .build

package:
	node scripts/package-app.mjs --output-dir "$(PACKAGE_OUTPUT)"

smoke-test:
	@status=0; cleanup_status=0; \
	node scripts/package-app.mjs --output-dir "$(SMOKE_OUTPUT)" --smoke-test || status=$$?; \
	node scripts/clean-smoke-output.mjs "$(SMOKE_OUTPUT)" >/dev/null || cleanup_status=$$?; \
	if [ "$$status" -ne 0 ]; then exit "$$status"; fi; \
	exit "$$cleanup_status"

test-doctor:
	node --test scripts/test/doctor.test.mjs

test-packager:
	node --test scripts/test/package-app.test.mjs

test-contracts:
	node scripts/check-contracts.mjs
	node --test scripts/test/contracts.test.mjs

test-bridge:
	node --test Bridge/test/client.test.mjs Bridge/test/extension-runtime.test.mjs Bridge/test/protocol.test.mjs Bridge/test/session-observer.test.mjs

test-cli-probe:
	node --test Bridge/test/probe.test.mjs scripts/test/qualify-cli.test.mjs

test-core:
	./scripts/test-core

qualify-cli:
	@if [ -n "$(ACTIVE)" ] && [ "$(ACTIVE)" != "1" ]; then printf '%s\n' 'ACTIVE must be exactly 1 when set' >&2; exit 2; fi
	@if [ -n "$(PERMISSION_EVENTS)" ] && [ "$(PERMISSION_EVENTS)" != "1" ]; then printf '%s\n' 'PERMISSION_EVENTS must be exactly 1 when set' >&2; exit 2; fi
	node scripts/qualify-cli.mjs --consent "$(CONSENT)" $(if $(ACTIVE),--active,) $(if $(PERMISSION_EVENTS),--permission-events,)

qualify-terminals:
	./scripts/swiftpm run --package-path Packages/CopilotMicroKit --scratch-path Packages/CopilotMicroKit/.build CopilotMicroTerminalProbe

qualify-ghostty:
	@if [ "$(CONSENT)" != "I-authorize-read-only-ghostty-automation" ]; then printf '%s\n' 'CONSENT must be I-authorize-read-only-ghostty-automation' >&2; exit 2; fi
	./scripts/swiftpm run --package-path Packages/CopilotMicroKit --scratch-path Packages/CopilotMicroKit/.build CopilotMicroGhosttyProbe --consent="$(CONSENT)"

qualify-ghostty-roundtrip:
	@if [ "$(CONSENT)" != "I-authorize-temporary-ghostty-window-test" ]; then printf '%s\n' 'CONSENT must be I-authorize-temporary-ghostty-window-test' >&2; exit 2; fi
	./scripts/swiftpm run --package-path Packages/CopilotMicroKit --scratch-path Packages/CopilotMicroKit/.build CopilotMicroGhosttyProbe --round-trip --consent="$(CONSENT)"

qualify-hardware:
	@if [ "$(CONSENT)" != "I-own-this-device-read" ]; then printf '%s\n' 'CONSENT must be I-own-this-device-read' >&2; exit 2; fi
	./scripts/swiftpm run --package-path Packages/CopilotMicroKit --scratch-path Packages/CopilotMicroKit/.build CopilotMicroHardwareProbe

observe-device-input:
	@if [ "$(CONSENT)" != "I-own-this-device-observe-input" ]; then printf '%s\n' 'CONSENT must be I-own-this-device-observe-input' >&2; exit 2; fi
	./scripts/swiftpm run --package-path Packages/CopilotMicroKit --scratch-path Packages/CopilotMicroKit/.build CopilotMicroInputObserver --consent="$(CONSENT)" --seconds="$(or $(SECONDS),30)"

qualify-device-lighting:
	@if [ "$(CONSENT)" != "I-closed-other-device-configurators-and-authorize-key-lighting-test" ]; then printf '%s\n' 'CONSENT must be I-closed-other-device-configurators-and-authorize-key-lighting-test' >&2; exit 2; fi
	./scripts/swiftpm run --package-path Packages/CopilotMicroKit --scratch-path Packages/CopilotMicroKit/.build CopilotMicroLightingProbe --consent="$(CONSENT)" --hold-seconds="$(or $(HOLD_SECONDS),2)"

preview-device-mapping:
	@if [ "$(CONSENT)" != "I-own-this-device-read" ]; then printf '%s\n' 'CONSENT must be I-own-this-device-read' >&2; exit 2; fi
	./scripts/swiftpm run --package-path Packages/CopilotMicroKit --scratch-path Packages/CopilotMicroKit/.build CopilotMicroDeviceSetup preview --consent="$(CONSENT)"

apply-device-mapping:
	@if [ -z "$(PLAN_SHA)" ]; then printf '%s\n' 'PLAN_SHA is required from preview-device-mapping' >&2; exit 2; fi
	@if [ "$(CONSENT)" != "I-closed-other-device-configurators-and-authorize-one-write" ]; then printf '%s\n' 'CONSENT must be I-closed-other-device-configurators-and-authorize-one-write' >&2; exit 2; fi
	./scripts/swiftpm run --package-path Packages/CopilotMicroKit --scratch-path Packages/CopilotMicroKit/.build CopilotMicroDeviceSetup apply --plan-sha="$(PLAN_SHA)" --consent="$(CONSENT)"

preview-device-restore:
	@if [ "$(CONSENT)" != "I-own-this-device-read" ]; then printf '%s\n' 'CONSENT must be I-own-this-device-read' >&2; exit 2; fi
	./scripts/swiftpm run --package-path Packages/CopilotMicroKit --scratch-path Packages/CopilotMicroKit/.build CopilotMicroDeviceSetup preview-restore --consent="$(CONSENT)"

restore-device-mapping:
	@if [ -z "$(PLAN_SHA)" ]; then printf '%s\n' 'PLAN_SHA is required from preview-device-restore' >&2; exit 2; fi
	@if [ "$(CONSENT)" != "I-closed-other-device-configurators-and-authorize-one-restore" ]; then printf '%s\n' 'CONSENT must be I-closed-other-device-configurators-and-authorize-one-restore' >&2; exit 2; fi
	./scripts/swiftpm run --package-path Packages/CopilotMicroKit --scratch-path Packages/CopilotMicroKit/.build CopilotMicroDeviceSetup restore --plan-sha="$(PLAN_SHA)" --consent="$(CONSENT)"

lint:
	node --check scripts/doctor
	node --check scripts/doctor.mjs
	node --check scripts/test/doctor.test.mjs
	node --check scripts/package-app.mjs
	node --check scripts/clean-smoke-output.mjs
	node --check scripts/check-contracts.mjs
	node --check scripts/test/package-app.test.mjs
	node --check scripts/test/contracts.test.mjs
	node --check scripts/qualify-cli.mjs
	node --check scripts/test/qualify-cli.test.mjs
	node --check Bridge/src/protocol.mjs
	node --check Bridge/src/client.mjs
	node --check Bridge/src/session-observer.mjs
	node --check Bridge/src/extension-runtime.mjs
	node --check Bridge/src/extension.mjs
	node --check Bridge/probe/probe-core.mjs
	node --check Bridge/probe/extension.mjs
	node --check Bridge/test/protocol.test.mjs
	node --check Bridge/test/client.test.mjs
	node --check Bridge/test/session-observer.test.mjs
	node --check Bridge/test/extension-runtime.test.mjs
	node --check Bridge/test/probe.test.mjs
	/bin/bash -n scripts/swiftpm
	/bin/bash -n scripts/test-core
	/usr/bin/xcrun swift format lint --configuration .swift-format --strict --recursive $(SWIFT_SOURCES)

format:
	/usr/bin/xcrun swift format format --configuration .swift-format --in-place --recursive $(SWIFT_SOURCES)

check: lint
	$(MAKE) test-doctor
	$(MAKE) test-packager
	$(MAKE) test-contracts
	$(MAKE) test-bridge
	$(MAKE) test-cli-probe
	$(MAKE) test-core
	$(MAKE) smoke-test
