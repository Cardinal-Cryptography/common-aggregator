# Common Aggregator

Yield aggregator for multiple ERC-4626 vaults, enabling a simple interaction via the ERC-4626 interface for users,
while providing additional features like rebalancing and vault management to the *Management*.

When depositing assets, users review the aggregator parameters set by *Management*, including
aggregated vaults and protocols corresponding to them, the maximum allocation limits for each of the aggregated vaults,
and the performance fee, understanding and agreeing to the risks associated with them.
Then, the *Rebalancer* chosen by *Management* can rebalance assets between protocols, according to their
strategy for optimizing between yield and risk.

## Aggregation features

### Funds distribution

By default, user deposits and withdrawals do not change proportions of the funds distributed between aggregated vaults.

Exception to this rule is a situation in which withdrawing the desired amount from one of the vaults is not possible at the moment.
In such a case, aggregator will withdraw disregarding the current proportions, prioritizing that the user is able to withdraw at all. 

### `ERC4626BufferedUpgradeable` - reward buffering

We implement an abstract contract `ERC4626BufferedUpgradeable` from which `CommonAggregator` inherits the reward buffering feature.

Reward buffering ensures that incoming `asset`s will be distributed to the depositors over some longer period of time, instead of instantly.
Its goal is to prevent potential attack in which user deposits right before a reward distribution event,
effectively capturing a portion of share holders' rewards for themselves.

### State updates

For reward buffer to function properly it needs to be updated, so that newly gained `assets`s are accounted for,
and later distributed to share holders. `ERC4626BufferedUpgradeable` specifies `updateHoldingsState` method, 
which can be called permissionlessly to update the buffer's state.

In `CommonAggregator`, such an update is run before each deposit and withdrawal action, so that the price-per-share
used for minting/burning shares is computed based on the latest data.
Additionally, it is recommended to deploy an off-chain component that will run updates in case there is no user activity
for long periods of time.

### Reward trading

`CommonAggregator` makes it possible to distribute rewards which are paid out in tokens different than the `asset` token (eg. boosting airdrops).
It is achieved by allowing *Management* to designate a *reward trader* for such a token - an address to which given token can be freely transferred.

The intended usage of this feature is that *reward trader* should be a non-upgradable contract, which has a single method 
trading the given token for `asset` (on some decentralized exchange) and tranferring it back to aggregator.

It is also possible for *reward trader* to be a trusted EOA in cases when CEX trading or other complex interactions are required. 

### Fees

Aggregator allows *Management* to set performance fee and its receiver.
Performance fee is taken as percantage of the gain (calculated and paid out during reward buffer's state update).

## Security
The `CommonManagement` contract implements the role-management and extra security layer to the aggregator,
Let's assume in this section the *Management* is a deployed instance of the `CommonManagement` contract.
Any security-sensitive actions by it, like adding a new vault to the protocol, are timelocked. This allows users
to react and withdraw their assets when they no longer agree with the strategy proposed by the *Management*.

Additionally, the *Management* can designate *Guardians* to monitor the protocol, and react by pausing it when unexpected
events occur, or cancel any incorrectly submitted timelocked actions. Importantly, even when the protocol is paused, users
can redeem their shares using the `emergencyRedeem` method, in exchange for shares of their underlying vaults.

### Roles

`CommonManagement` defines several roles, with different sets of privileges.

*Owner* - owner of the `CommonManagement` contract. Has ability to assign and revoke all other roles
and has all of their privileges. Can upgrade `CommonManagement` and `CommonAggregator` contracts (subject to a timelock).

*Manager* - role performing management actions for `CommonAggregator`, less privilaged than *Owner*.
Has ability to add/remove aggregated vaults and set *reward traders* (both subject to a timelock). 
Has all privileges of *Guardian* and *Rebalancer*.

*Guardian* - role for quickly responding to incidents/mistakes. Can pause deposits/withdrawals and cancel timelocked actions.

*Rebalancer* - can move funds between vaults to maximize gain or limit risk (subject to limits specified by the owner).

## Development

### Configuration

In order to pass arguments to `make` instructions that follow, copy contents of `.env.example` to `.env` and fill in the values.

### Install dependencies

```
make deps
```

### Compile solidity contracts

```
make compile-contracts
```

### Running tests

```
make test
```

### Bulding and serving docs locally

```
make doc-local
```
