// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {ReapMorphoIntegration} from "./ReapMorphoIntegration.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IWrapped} from "./interfaces/IWrapped.sol";
import {IPermit2} from "lib/permit2/src/interfaces/IPermit2.sol";
// Import console.log
import "forge-std/console.sol";

contract ReapLiquidityRouter is Ownable, ReapMorphoIntegration, BaseHook {
    using StateLibrary for IPoolManager;

    mapping(PoolId => bool) public isReapPool;
    mapping(PoolId => uint256) public tokenIdToPoolKey;

    IPositionManager positionManager;
    IPermit2 permit2;

    constructor(IPoolManager _manager, IPositionManager _positionManager, IPermit2 _permit2, address _WETH)
        Ownable(msg.sender)
        BaseHook(_manager)
        ReapMorphoIntegration(_WETH)
    {
        positionManager = _positionManager;
        permit2 = _permit2;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // check that the given pool is a reap pool
        if (!isReapPool[key.toId()]) {
            revert("ReapLiquidityRouter: Not a reap pool");
        }

        address asset0 = Currency.unwrap(key.currency0);
        address vaultAddressAsset0;
        if (key.currency0.isAddressZero()) {
            vaultAddressAsset0 = morphoAssetToVault[WETH];
        } else {
            vaultAddressAsset0 = morphoAssetToVault[asset0];
        }

        address asset1 = Currency.unwrap(key.currency1);
        address vaultAddressAsset1 = morphoAssetToVault[asset1];

        if (vaultAddressAsset0 == address(0) || vaultAddressAsset1 == address(0)) {
            revert("ReapLiquidityRouter: No vault address found for asset");
        }

        // Now withdraw all the assets from the vault
        withdrawAll(vaultAddressAsset0);
        withdrawAll(vaultAddressAsset1);

        // Now we get the balance of asset 1
        uint256 asset1Amount = IERC20(asset1).balanceOf(address(this));

        uint256 asset0Amount;
        if (asset0 == address(0)) {
            uint256 WETHBalance = IWrapped(WETH).balanceOf(address(this));
            IWrapped(WETH).withdraw(WETHBalance);
            asset0Amount = address(this).balance;
            console.log("asset0 amount after withdraw", asset0Amount);
        } else {
            asset0Amount = IERC20(asset0).balanceOf(address(this));
        }

        _addLiquidityToPool(key, asset0Amount, asset1Amount, asset0, asset1);
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        // CHeck if the pool is a reap pool
        if (!isReapPool[key.toId()]) {
            revert("ReapLiquidityRouter: Not a reap pool");
        }

        bytes memory actions = abi.encodePacked(bytes1(uint8(Actions.BURN_POSITION)), bytes1(uint8(Actions.TAKE_PAIR)));

        bytes[] memory params = new bytes[](2);

        // Get the tokenId of the position from the mapping
        uint256 tokenId = tokenIdToPoolKey[key.toId()];

        if (tokenId == 0) {
            revert("ReapLiquidityRouter: No tokenId found for the pool");
        }

        // Parameters for BURN_POSITION
        params[0] = abi.encode(
            tokenId, // Position to burn
            0, // Minimum token0 to receive
            0, // Minimum token1 to receive
            "" // No hook data needed
        );

        // Parameters for TAKE_PAIR - where tokens will go
        params[1] = abi.encode(
            key.currency0, // First token
            key.currency1, // Second token
            address(this) // Who receives the tokens
        );

        positionManager.modifyLiquiditiesWithoutUnlock(actions, params);

        _addLiquidityBackToMorpho(key);

        return (BaseHook.afterSwap.selector, 0);
    }

    function _afterInitialize(address, PoolKey calldata key, uint160, int24) internal override returns (bytes4) {
        // We need to give permit2 contract approval for both the currency0 and currency1 tokens

        if (!key.currency0.isAddressZero()) {
            // Given max approval to permit2 contract for this asset
            IERC20(Currency.unwrap(key.currency0)).approve(address(permit2), type(uint256).max);
        }

        IERC20(Currency.unwrap(key.currency1)).approve(address(permit2), type(uint256).max);

        return BaseHook.afterInitialize.selector;
    }

    function modifyLiquidity(PoolKey memory poolKey, uint256 asset0Amount, uint256 asset1Amount) external payable {
        return _modifyLiquidity(poolKey, asset0Amount, asset1Amount);
    }

    // HELPER FUNCTIONS //

    /**
     * @notice Adds liquidity to the uniswap pool which was withdrawn from the morpho vault
     * @param key The pool key
     * @param asset0Amount The amount of asset0 to add
     * @param asset1Amount The amount of asset1 to add
     * @param asset0 The address of asset0
     * @param asset1 The address of asset1
     */
    function _addLiquidityToPool(
        PoolKey memory key,
        uint256 asset0Amount,
        uint256 asset1Amount,
        address asset0,
        address asset1
    ) internal {
        // 1. MINT_POSITION - Creates the position and calculates token requirements
        // 2. SETTLE_PAIR - Provides the tokens needed
        bytes memory actions =
            abi.encodePacked(bytes1(uint8(Actions.MINT_POSITION)), bytes1(uint8(Actions.SETTLE_PAIR)));
        bytes[] memory modifyLiquidityParams = new bytes[](2);

        int24 tickLower = TickMath.minUsableTick(key.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(key.tickSpacing);

        (uint160 currentSqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        console.log("currentSqrtPriceX96", currentSqrtPriceX96);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            currentSqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            asset0Amount,
            asset1Amount
        );

        console.log("liquidity", liquidity);

        // Parameters for MINT_POSITION
        modifyLiquidityParams[0] = abi.encode(
            key,
            tickLower,
            tickUpper,
            liquidity, // Amount of liquidity to mint
            asset0Amount, // Maximum amount of token0 to use
            asset1Amount, // Maximum amount of token1 to use
            address(this), // Who receives the NFT
            "" // No hook data needed
        );

        // Parameters for SETTLE_PAIR - specify tokens to provide
        modifyLiquidityParams[1] = abi.encode(
            key.currency0, // First token to settle
            key.currency1 // Second token to settle
        );

        // Approve tokens to the position manager
        if (asset0 != address(0)) {
            IERC20(asset0).approve(address(positionManager), asset0Amount);
        }

        IERC20(asset1).approve(address(positionManager), asset1Amount);
        uint256 tokenId = positionManager.nextTokenId();

        tokenIdToPoolKey[key.toId()] = tokenId;

        // Give allowance to position manager contract using permit2 for asset1
        IPermit2(permit2).approve(
            asset1, address(positionManager), uint160(asset1Amount), uint48(block.timestamp + 1000)
        );

        if (asset0 == address(0)) {
            // Print the balance of asset1 before modifying liquidity
            console.log(IERC20(asset1).balanceOf(address(this)));
            console.log("asset1 amount", asset1Amount);
            console.log("asset0 amount", asset0Amount);
            positionManager.modifyLiquiditiesWithoutUnlock{value: asset0Amount}(actions, modifyLiquidityParams);
        } else {
            // Give allowance to position manager contract using permit2 for asset0 only if its not ETH
            IPermit2(permit2).approve(
                asset0, address(positionManager), uint160(asset0Amount), uint48(block.timestamp + 1000)
            );
            positionManager.modifyLiquiditiesWithoutUnlock(actions, modifyLiquidityParams);
        }
    }

    function _addLiquidityBackToMorpho(PoolKey memory key) internal {
        // Convert currency0 to assetAddress
        address asset0Address = Currency.unwrap(key.currency0);

        // Convert currency1 to assetAddress
        address asset1Address = Currency.unwrap(key.currency1);
        // Get the vault address for asset0 and asset1
        address vaultAddressAsset0;
        if (asset0Address == address(0)) {
            vaultAddressAsset0 = morphoAssetToVault[WETH];
        } else {
            vaultAddressAsset0 = morphoAssetToVault[asset0Address];
        }
        address vaultAddressAsset1 = morphoAssetToVault[asset1Address];

        if (vaultAddressAsset0 == address(0) || vaultAddressAsset1 == address(0)) {
            revert("ReapLiquidityRouter: No vault address found for asset");
        }
        uint256 asset0Amount;
        uint256 asset1Amount;
        // Get the balance of asset0 and asset1
        if (asset0Address == address(0)) {
            asset0Amount = address(this).balance;
        } else {
            asset0Amount = IERC20(asset0Address).balanceOf(address(this));
        }

        asset1Amount = IERC20(asset1Address).balanceOf(address(this));

        processMorphoAssetDeposit(asset0Address, asset0Amount, vaultAddressAsset0, key);
        processMorphoAssetDeposit(asset1Address, asset1Amount, vaultAddressAsset1, key);
    }

    function _modifyLiquidity(PoolKey memory poolKey, uint256 asset0Amount, uint256 asset1Amount) internal {
        PoolId pookKeyId = poolKey.toId();
        if (!isReapPool[pookKeyId]) {
            revert("ReapLiquidityRouter: Not a reap pool");
        }
        // Get asset 0 address
        Currency assetCurrency0 = poolKey.currency0;
        address asset0 = Currency.unwrap(assetCurrency0);
        address vaultAddressAsset0;
        if (asset0 == address(0)) {
            vaultAddressAsset0 = morphoAssetToVault[WETH];
            if (vaultAddressAsset0 == address(0)) {
                revert("ReapLiquidityRouter: No vault address found for asset");
            }
        }
        // get asset 1 address
        Currency assetCurrency1 = poolKey.currency1;
        address asset1 = Currency.unwrap(assetCurrency1);
        // Check if a vault address exists for the asset

        // Check if a vault address exists for the asset
        address vaultAddressAset1 = morphoAssetToVault[asset1];
        if (vaultAddressAset1 == address(0)) {
            revert("ReapLiquidityRouter: No vault address found for asset");
        }

        if (asset0 == address(0)) {
            require(msg.value == asset0Amount, "User sent less ETH than required");
        }

        processMorphoAssetDeposit(asset0, asset0Amount, vaultAddressAsset0, poolKey);

        mintReapLPToken(poolKey, asset0, asset0Amount);
        emit ReapLPTokenMinted(poolKey, asset0, asset0Amount);

        processMorphoAssetDeposit(asset1, asset1Amount, vaultAddressAset1, poolKey);
        mintReapLPToken(poolKey, asset1, asset1Amount);
        emit ReapLPTokenMinted(poolKey, asset1, asset1Amount);
    }

    function setIsReapPool(PoolKey memory poolKey, bool isValid) external onlyOwner {
        // Get PoolId
        PoolId pookKeyId = poolKey.toId();
        isReapPool[pookKeyId] = isValid;
    }

    // TODO: maybe we can move this to ReapMorphoIntegration
    function setMorphoAssetToVault(address _assetAddress, address _vaultAddress) external onlyOwner {
        morphoAssetToVault[_assetAddress] = _vaultAddress;
    }

    function deleteMorphoAssetToVault(address _assetAddress) external onlyOwner {
        delete morphoAssetToVault[_assetAddress];
    }

    function setWETH(address _WETH) external onlyOwner {
        WETH = _WETH;
    }

    receive() external payable {}
}
