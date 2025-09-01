// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IMetaMorpho, MarketAllocation} from "lib/metamorpho/src/interfaces/IMetaMorpho.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IWrapped} from "./interfaces/IWrapped.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import "forge-std/console.sol";

// TODO: create interfaces

contract ReapMorphoIntegration is ERC1155 {
    address WETH;

    event WithdrawalFromMorphoVault(uint256 amount);
    event MorphoDeposit(uint256 amount, uint256 minted);
    event ReapLPTokenMinted(PoolKey poolKey, address asset, uint256 amount);

    // Mapping from asset address to vault address

    mapping(address => address) public morphoAssetToVault;
    mapping(PoolId => mapping(address => uint256)) public poolToMorphoShares;
    mapping(uint256 => uint256) public totalSupply;

    constructor(address _WETH) ERC1155("") {
        WETH = _WETH;
    }

    // TODO: also add the functionality to process withdrawals
    function processMorphoAssetDeposit(address assetAddress, uint256 amount, address spender, PoolKey memory key)
        internal
        returns (uint256)
    {
        address vaultAddressAsset;
        if (assetAddress == address(0)) {
            vaultAddressAsset = morphoAssetToVault[WETH];
        } else {
            vaultAddressAsset = morphoAssetToVault[assetAddress];
        }

        if (vaultAddressAsset == address(0)) {
            revert("ReapLiquidityRouter: No vault address found for asset");
        }

        // Check if the address is ETH
        if (assetAddress == address(0)) {
            IWrapped(WETH).deposit{value: amount}();
            // Approve WETH to Morpho Vault
            IERC20(WETH).approve(vaultAddressAsset, amount);
        } else {
            // TODO: check what is the significance of bool in wrapped assets
            // Transfer assetAddress to msg.sender
            // TODO: change this code
            if (spender != address(this)) {
                IERC20(assetAddress).transferFrom(spender, address(this), amount);
            }
            // Give vault the approval
            IERC20(assetAddress).approve(vaultAddressAsset, amount);
        }

        // Call depositIntoMorphoVault
        return depositIntoMorphoVault(amount, vaultAddressAsset, assetAddress, key);
    }

    function depositIntoMorphoVault(uint256 amount, address vaultAddress, address asset, PoolKey memory key)
        internal
        returns (uint256)
    {
        uint256 sharedMinted = IMetaMorpho(vaultAddress).deposit(amount, address(this));
        PoolId poolId = key.toId();

        // TODO: maybe shares minted should equal to the ERC1155 tokens that are minted to the user
        emit MorphoDeposit(amount, sharedMinted);
        poolToMorphoShares[poolId][asset] = poolToMorphoShares[poolId][asset] + sharedMinted;
        return sharedMinted;
    }

    function withdrawFromMorphoVault(PoolKey memory key, uint256 shares, address asset, address sender)
        internal
        returns (uint256)
    {
        PoolId poolId = key.toId();
        uint256 existingShares = poolToMorphoShares[poolId][asset];

        if (existingShares < shares || shares == 0) {
            revert("ReapLiquidityRouter: Not enough balance of Morpho shares");
        }

        // Get vault address
        address vaultAddress;
        if (asset == address(0)) {
            vaultAddress = morphoAssetToVault[WETH];
            uint256 wethAmount = IMetaMorpho(vaultAddress).redeem(shares, address(this), address(this));
            IWrapped(WETH).withdraw(wethAmount);
            (bool success,) = payable(sender).call{value: wethAmount}("");
            if (!success) {
                revert("ReapLiquidityRouter: ETH transfer failed");
            }
        } else {
            vaultAddress = morphoAssetToVault[asset];
            IMetaMorpho(vaultAddress).redeem(shares, sender, address(this));
        }

        poolToMorphoShares[poolId][asset] = poolToMorphoShares[poolId][asset] - shares;
        return shares;
    }

    function tokensToMint(
        uint256 liquidity,
        uint256 amount0,
        uint256 amount1,
        uint256 existingAmount0,
        uint256 existingAmount1
    ) public pure returns (uint256) {
        if (liquidity == 0) {
            console.log("liquidity", liquidity);
            return Math.sqrt(amount0 * amount1);
        } else {
            console.log("coming inside tokenToMint else condition");
            uint256 existingLiquidityAmount0 = Math.mulDiv(liquidity, amount0, existingAmount0);
            console.log("existingLiquidityAmount0", existingLiquidityAmount0);
            uint256 existingLiquidityAmount1 = Math.mulDiv(liquidity, amount1, existingAmount1);
            console.log("existingLiquidityAmount1", existingLiquidityAmount1);
            return Math.min(existingLiquidityAmount0, existingLiquidityAmount1);
        }
    }

    function mint(PoolKey memory poolKey, uint256 amount0, uint256 amount1) internal {
        uint256 erc1155ID = uint256(PoolId.unwrap(poolKey.toId()));
        uint256 liquidity = totalSupply[erc1155ID];

        // Get the vault address for asset0
        address asset0 = Currency.unwrap(poolKey.currency0);
        address vaultAddressAsset0;
        if (asset0 == address(0)) {
            vaultAddressAsset0 = morphoAssetToVault[WETH];
        } else {
            vaultAddressAsset0 = morphoAssetToVault[asset0];
        }
        // Get the vault address for asset1
        address asset1 = Currency.unwrap(poolKey.currency1);
        address vaultAddressAsset1 = morphoAssetToVault[asset1];

        // Now I need to get the liquidity of asset0 and asset1 from Morpho pool

        uint256 asset0Shares = poolToMorphoShares[poolKey.toId()][asset0];
        uint256 balance0 = IMetaMorpho(vaultAddressAsset0).previewRedeem(asset0Shares);

        uint256 asset1Shares = poolToMorphoShares[poolKey.toId()][asset1];
        uint256 balance1 = IMetaMorpho(vaultAddressAsset1).previewRedeem(asset1Shares);

        uint256 totalLpToken = tokensToMint(liquidity, amount0, amount1, balance0, balance1);

        totalSupply[erc1155ID] += totalLpToken;
        _mint(msg.sender, erc1155ID, totalLpToken, "");
    }

    function burn(PoolKey memory key, uint256 amount) public {
        // Check that user has enough balance in Reap LP Token
        uint256 erc1155ID = uint256(PoolId.unwrap(key.toId()));
        uint256 balance = balanceOf(msg.sender, erc1155ID);
        if (balance < amount) {
            revert("ReapLiquidityRouter: Not enough balance of Reap LP Token");
        }

        // Now we need to calculate percentage of balance so that we can burn correct amount of Reap LP Token
        // Get the address
        address asset0 = Currency.unwrap(key.currency0);
        address asset1 = Currency.unwrap(key.currency1);

        // Get the balance of asset from Morpho
        uint256 asset0Shares = poolToMorphoShares[key.toId()][asset0];
        uint256 asset1Shares = poolToMorphoShares[key.toId()][asset1];

        // Calulate percentage ownership of the user
        uint256 userShareAsset0 = asset0Shares * balance / totalSupply[erc1155ID];
        uint256 userShareAsset1 = asset1Shares * balance / totalSupply[erc1155ID];

        totalSupply[erc1155ID] -= amount;

        // Withdraw from Morpho vault
        withdrawFromMorphoVault(key, userShareAsset0, asset0, msg.sender);
        withdrawFromMorphoVault(key, userShareAsset1, asset1, msg.sender);

        _burn(msg.sender, erc1155ID, amount);
    }
}
