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

.PHONY: lint
lint: # Run lint via solhint
lint:
	pnpm solhint contracts/interfaces/*.sol contracts/*.sol scripts/*.sol

.PHONY: benchmark
benchmark: # Run benchmark
benchmark:
	forge test --match-test Benchmark --gas-report
