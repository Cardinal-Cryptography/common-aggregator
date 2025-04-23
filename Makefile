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
	forge coverage --no-match-coverage='^(scripts|tests|contracts/testnet)' --report lcov --report-file coverage/lcov.info
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

.PHONY: deploy-mocks-on-testnet
deploy-mocks-on-testnet: # Deploy mocks on testnet
deploy-mocks-on-testnet:
	@echo "Deploying mocks on testnet..."
	@forge script ./scripts/testnet/DeploySteadyTestnetVault.s.sol --rpc-url ${RPC_URL} --private-key ${DEPLOYER_PRIVATE_KEY} --broadcast --verify --verifier blockscout
	@forge script ./scripts/testnet/DeployRandomWalkTestnetVaults.s.sol --rpc-url ${RPC_URL} --private-key ${DEPLOYER_PRIVATE_KEY} --broadcast --verify --verifier blockscout

.PHONY: deploy-aggregator
deploy-aggregator: # Deploy aggregator
deploy-aggregator:
	@echo "Building contracts with full profile..."
	FOUNDRY_PROFILE=full forge clean;
	FOUNDRY_PROFILE=full forge build;
	@if [ "${DEPLOY_BROADCAST}" = "true" ]; then \
		echo "Deploying aggregator..."; \
		FOUNDRY_PROFILE=full forge script ./scripts/DeployAggregator.s.sol --rpc-url ${RPC_URL} --private-key ${DEPLOYER_PRIVATE_KEY} --broadcast --verify --verifier blockscout; \
	else \
		echo "Dry-running deployment of aggregator. To deploy, edit DEPLOY_BROADCAST flag in .env"; \
		FOUNDRY_PROFILE=full forge script ./scripts/DeployAggregator.s.sol --rpc-url ${RPC_URL} --private-key ${DEPLOYER_PRIVATE_KEY}; \
	fi

.ONESHELL:
.PHONY: local-devnet
local-devnet: # Run local devnet with test vaults and aggregator (on anvil)
local-devnet:
	@bash local_devnet.sh
