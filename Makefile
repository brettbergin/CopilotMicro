.DEFAULT_GOAL := help

PACKAGE_OUTPUT ?= build/package-$(shell /usr/bin/uuidgen)
SWIFT_SOURCES := Package.swift App/Sources Packages/CopilotMicroKit/Package.swift Packages/CopilotMicroKit/Sources Packages/CopilotMicroKit/Tests

.PHONY: help doctor doctor-xcode build package smoke-test test-doctor test-packager test-core lint format check

help:
	@printf '%s\n' \
		'doctor-xcode  Check the optional full-Xcode environment without changing settings' \
		'doctor        Check local Swift/macOS SDK prerequisites with CLT or Xcode' \
		'build         Compile the native arm64 app with SwiftPM' \
		'package       Build and ad-hoc sign an app in a fresh build/package-* directory' \
		'smoke-test    Package the app and verify hidden native UI and resources' \
		'test-doctor   Run isolated prerequisite-checker tests' \
		'test-packager Run isolated packaging safety tests' \
		'test-core     Run the Core package Swift Testing suite without XCTest' \
		'lint          Check JavaScript syntax and Swift formatting' \
		'format        Apply the repository Swift formatting configuration' \
		'check         Run local tooling, Core and headless native checks; no live integrations'

doctor:
	node scripts/doctor.mjs

doctor-xcode:
	node scripts/doctor.mjs --phase xcode

build:
	/usr/bin/xcrun swift build --arch arm64 --jobs 2

package:
	node scripts/package-app.mjs --output-dir "$(PACKAGE_OUTPUT)"

smoke-test:
	node scripts/package-app.mjs --output-dir "$(PACKAGE_OUTPUT)" --smoke-test

test-doctor:
	node --test scripts/test/doctor.test.mjs

test-packager:
	node --test scripts/test/package-app.test.mjs

test-core:
	./scripts/test-core

lint:
	node --check scripts/doctor
	node --check scripts/doctor.mjs
	node --check scripts/test/doctor.test.mjs
	node --check scripts/package-app.mjs
	node --check scripts/test/package-app.test.mjs
	/bin/bash -n scripts/test-core
	/usr/bin/xcrun swift format lint --configuration .swift-format --strict --recursive $(SWIFT_SOURCES)

format:
	/usr/bin/xcrun swift format format --configuration .swift-format --in-place --recursive $(SWIFT_SOURCES)

check: lint
	$(MAKE) test-doctor
	$(MAKE) test-packager
	$(MAKE) test-core
	$(MAKE) smoke-test
