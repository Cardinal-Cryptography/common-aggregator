# Common Aggregator

Yield aggregator for multiple ERC-4626 vaults, enabling a simple interaction via the ERC-4626 interface for users,
while providing additional features like rebalancing and vault management to the *Management*.

When depositing assets, users review the aggregator parameters set by *Management*, including
aggregated vaults and protocols corresponding to them, the maximum allocation limits for each of the aggregated vaults,
and the performance fee, understanding and agreeing to the risks associated with them.
Then, the *Rebalancer* chosen by *Management* can rebalance assets between protocols, according to their
strategy for optimizing between yield and risk.

### Security
The `CommonManagement` contract implements the role-management and extra security layer to the aggregator,
Let's assume in this section the *Management* is a deployed instance of the `CommonManagement` contract.
Any security-sensitive actions by it, like adding a new vault to the protocol, are timelocked. This alllows users
to react and withdraw their assets when they no longer agree with the strategy proposed by the *Management*.

Additionally, the *Management* can designate *Guardians* to monitor the protocol, and react by pausing it when unexpected
events occur, or cancel any incorrectly submitted timelocked actions. Importantly, even when the protocol is paused, users can still withdraw their assets
using the `emergencyRedeem` method.

## Development

### Install dependencies

```
make deps
```

### Compile solidity contracts

```
make compile-contracts
```
