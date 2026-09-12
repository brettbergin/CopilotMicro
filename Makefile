.DEFAULT_GOAL := help

.PHONY: help doctor doctor-xcode test-doctor check

help:
	@printf '%s\n' \
		'doctor-xcode  Check full Xcode and its macOS SDK without changing settings' \
		'doctor        Report required and optional developer prerequisites' \
		'test-doctor   Run isolated prerequisite-checker tests' \
		'check         Check setup tooling only; no native app exists yet'

doctor:
	node scripts/doctor.mjs

doctor-xcode:
	node scripts/doctor.mjs --phase xcode

test-doctor:
	node --test scripts/test/doctor.test.mjs

check:
	@printf '%s\n' 'Checking developer setup tooling only; native app not implemented.'
	node --check scripts/doctor
	node --check scripts/doctor.mjs
	node --check scripts/test/doctor.test.mjs
	$(MAKE) test-doctor
