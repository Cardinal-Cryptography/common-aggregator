-include .env
ifeq ($(wildcard .env),)
$(error .env: No such file or directory (copy .env.example to .env and fill in the values))
endif

.PHONY: help
help: # Show help for each of the Makefile recipes.
	@grep -E '^[a-zA-Z0-9 -]+:.*#'  Makefile | sort | while read -r l; do printf "\033[1;32m$$(echo $$l | cut -f 1 -d':')\033[00m:$$(echo $$l | cut -f 2- -d'#')\n"; done

.PHONY: deps
deps: # Install all the dependencies
deps:
	pnpm install

.PHONY: compile-contracts
compile-contracts: # Compile solidity contracts
compile-contracts:
	forge build

.PHONY: test
test: # Run tests
test:
	forge test

.PHONY: coverage-contracts
coverage-contracts: # Run coverage
coverage-contracts:
	mkdir -p coverage
	forge coverage --no-match-coverage='^(scripts|tests)' --report lcov --report-file coverage/lcov.info
	@if ! genhtml coverage/lcov.info --branch-coverage --output-dir coverage; then \
		echo "Error generating coverage report. Maybe you haven't installed lcov"; \
		exit 1; \
	fi
	@echo "Coverage report generated at coverage/index.html"

.PHONY: fmt
fmt: # Format contracts
fmt:
	forge fmt

.PHONY: lint
lint: # Run lint via solhint
lint:
	pnpm solhint contracts/interfaces/*.sol contracts/*.sol scripts/*.sol

.PHONY: benchmark
benchmark: # Run benchmark
benchmark:
	forge test --match-test Benchmark --gas-report

.PHONY: doc-local
doc-local: # Generate documentation for local usage
doc-local:
	forge doc --serve --port 14719
