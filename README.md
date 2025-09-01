# Reap Hook

## Overview

Reap is a hook and router which allows rehypothecation of Uniswap v4 liquidity pools. It is built on top of the [Morpho Vaults](https://docs.morpho.org/build/).

## Design

### Adding and Removing Liquidity

The flow begins when a user deposits liquidity through the ReapHook. They call the `addLiquidity` function on the Reap Hook, which maintains the pool’s price using the Uniswap V2 full-range liquidity model. The appropriate amounts are deposited into Morpho Vaults, and the hook mints Reap LP tokens to the user.

The number of Reap LP tokens minted is determined by the Uniswap V2 formula:

```solidity
if (existingLiquidity == 0) {
    return Math.sqrt(amount0 * amount1);
}

L_x = Math.mulDiv(existingLiquidity, amount0AddedByTheUser, balance0OfTheVault);
L_y = Math.mulDiv(existingLiquidity, amount1AddedByTheUser, balance1OfTheVault);
return Math.min(L_x, L_y);
```

Later, the user can withdraw liquidity from the Reap Hook by calling the `removeLiquidity` function. The Reap Hook will burn the LP tokens and return the user’s tokens.

Using the Uniswap V2 formula for minting LP tokens guarantees that users always receive their proportional share back, which also includes any yield generated from the Morpho Vault.

### Swapping

The user swaps tokens in a Reap Pool through the Uniswap V4 Universal Router. The Reap Hook implements `beforeSwap`, which withdraws 100% of the pool’s tokens from the Morpho Vault before any swap and supplies them as liquidity to the Uniswap V4 pool using POSM.

After the swap, the Reap Hook executes afterSwap, which removes the liquidity from the pool, burns the Uniswap V4 position, and redeposits the tokens into the Morpho Vault.

Note: The hook also tracks any leftover tokens that were not added to the Uniswap V4 liquidity pool. These residual tokens are deposited back into the Morpho Vault during the afterSwap function.

## Testing

To run the tests, you need to set the following environment variables:

- `MAINNET_RPC_URL`: The RPC URL of the Ethereum mainnet.

### Building the project

To build the project, run the following command:

```sh
forge install
forge build
```

### Running the tests

To run the tests, run the following command:

```sh
forge test
```
