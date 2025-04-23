#!/bin/bash
set -e

# A key corresponding to address 0x70997970C51812dc3A010C7d01b50e0d17dc79C8 - second defaut anvil account
PRIVATE_KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
ANVIL_PORT=8545

# Needed for script that deploys the aggregator
export FOUNDRY_PROFILE=full

if nc -z localhost ${ANVIL_PORT}; then
  echo "Port ${ANVIL_PORT} already in use. Won't start new anvil instance."
else
  # Kill a single background job (anvil), when scripts is terminated or exits.
  trap "kill %1" SIGINT SIGTERM EXIT
  anvil > .anvil.log &
  echo "Waiting for devnet to start..."
fi

# Re-build to ensure that profile.full was used for generating artifacts
forge clean && forge build

# Deploy
forge script scripts/testnet/SetupDevnet.s.sol \
  --rpc-url http://localhost:${ANVIL_PORT} \
  --broadcast \
  --private-key ${PRIVATE_KEY}

# Display anvil logs
tail +1f .anvil.log
