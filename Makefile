.DEFAULT_GOAL := help

PACKAGE_OUTPUT ?= build/package-$(shell /usr/bin/uuidgen)
SMOKE_OUTPUT ?= build/smoke-$(shell /usr/bin/uuidgen)
SMOKE_OUTPUT := $(SMOKE_OUTPUT)
SWIFT_SOURCES := Package.swift App/Sources Packages/CopilotMicroKit/Package.swift Packages/CopilotMicroKit/Sources Packages/CopilotMicroKit/Tests

.PHONY: help doctor doctor-xcode build package smoke-test test-doctor test-packager test-contracts test-core lint format check

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
		'test-core     Run the Core package Swift Testing suite without XCTest' \
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

test-core:
	./scripts/test-core

lint:
	node --check scripts/doctor
	node --check scripts/doctor.mjs
	node --check scripts/test/doctor.test.mjs
	node --check scripts/package-app.mjs
	node --check scripts/clean-smoke-output.mjs
	node --check scripts/check-contracts.mjs
	node --check scripts/test/package-app.test.mjs
	node --check scripts/test/contracts.test.mjs
	/bin/bash -n scripts/swiftpm
	/bin/bash -n scripts/test-core
	/usr/bin/xcrun swift format lint --configuration .swift-format --strict --recursive $(SWIFT_SOURCES)

format:
	/usr/bin/xcrun swift format format --configuration .swift-format --in-place --recursive $(SWIFT_SOURCES)

check: lint
	$(MAKE) test-doctor
	$(MAKE) test-packager
	$(MAKE) test-contracts
	$(MAKE) test-core
	$(MAKE) smoke-test
