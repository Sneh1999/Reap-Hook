// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {IMetaMorpho} from "lib/metamorpho/src/interfaces/IMetaMorpho.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

contract ReapHook is Ownable, ERC1155, BaseHook {
    using StateLibrary for IPoolManager;

    IPositionManager public immutable posm;
    IPermit2 public immutable permit2;
    IWETH9 public immutable weth;

    uint256 transient amount0Excess;
    uint256 transient amount1Excess;

    mapping(PoolId => bool) public isReapPool;
    mapping(PoolId => uint256) public poolIdToPosMTokenId;
    mapping(PoolId => mapping(Currency => uint256)) public poolIdToMorphoShares;
    mapping(Currency => address) public currencyToMorphoVault;
    // Mapping from LP token ID to total supply
    mapping(uint256 => uint256) public lpTokenTotalSupply;

    error NotReapPool();
    error UnsupportedCurrency(Currency currency);
    error InsufficientAmount();
    error TransferFailed();

    constructor(IPoolManager _manager, IPositionManager _posm, IPermit2 _permit2, IWETH9 _weth)
        Ownable(msg.sender)
        ERC1155("")
        BaseHook(_manager)
    {
        posm = _posm;
        permit2 = _permit2;
        weth = _weth;
    }

    // --------------------- HOOKS ---------------------
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

    function _afterInitialize(address, PoolKey calldata key, uint160, int24) internal override returns (bytes4) {
        if (!key.currency0.isAddressZero()) {
            IERC20(Currency.unwrap(key.currency0)).approve(address(permit2), type(uint256).max);
        }
        IERC20(Currency.unwrap(key.currency1)).approve(address(permit2), type(uint256).max);
        return this.afterInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        if (!isReapPool[poolId]) return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        uint256 totalShares0 = poolIdToMorphoShares[poolId][key.currency0];
        uint256 totalShares1 = poolIdToMorphoShares[poolId][key.currency1];
        (uint256 amount0, uint256 amount1) = _redeemShares(key, totalShares0, totalShares1, address(this));
        (uint256 amount0Added, uint256 amount1Added) = _addLiquidityToPool(key, amount0, amount1);
        if (amount0 > amount0Added) {
            amount0Excess = amount0 - amount0Added;
        }
        if (amount1 > amount1Added) {
            amount1Excess = amount1 - amount1Added;
        }

        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        if (!isReapPool[poolId]) return (this.afterSwap.selector, 0);

        (uint256 amount0Withdrawn, uint256 amount1Withdrawn) = _removeLiquidityFromPool(key);
        uint256 totalAmount0 = amount0Withdrawn + amount0Excess;
        uint256 totalAmount1 = amount1Withdrawn + amount1Excess;

        if (key.currency0.isAddressZero()) {
            weth.deposit{value: totalAmount0}();
        }

        _depositAssets(key, totalAmount0, totalAmount1);

        return (this.afterSwap.selector, 0);
    }

    // --------------------- ROUTER ---------------------
    function addLiquidity(PoolKey calldata key, uint256 amount0Desired, uint256 amount1Desired)
        external
        payable
        returns (uint256)
    {
        PoolId poolId = key.toId();
        if (!isReapPool[poolId]) revert NotReapPool();

        uint256 lpTokenId = _getLpTokenId(key);
        uint256 existingLiquidity = lpTokenTotalSupply[lpTokenId];
        (uint256 balance0, uint256 balance1) = _getMorphoBalances(key);
        (uint256 amount0, uint256 amount1) = _getAmountsToAdd(amount0Desired, amount1Desired, balance0, balance1);

        // Transfer token0 and token1 from user to this contract
        // Refund any excess ETH they may have sent if token0 is native token
        if (key.currency0.isAddressZero()) {
            if (amount0 > msg.value) revert InsufficientAmount();
            weth.deposit{value: amount0}();

            // Refund extra ETH
            if (amount0 < msg.value) {
                (bool success,) = payable(msg.sender).call{value: msg.value - amount0}("");
                if (!success) revert TransferFailed();
            }
        } else {
            IERC20(Currency.unwrap(key.currency0)).transferFrom(msg.sender, address(this), amount0);
        }

        IERC20(Currency.unwrap(key.currency1)).transferFrom(msg.sender, address(this), amount1);

        // Mint LP tokens
        uint256 liquidity = _getLiquidityAmount(existingLiquidity, amount0, amount1, balance0, balance1);
        lpTokenTotalSupply[lpTokenId] += liquidity;
        _mint(msg.sender, lpTokenId, liquidity, "");

        // Deposit assets to Morpho Vault
        _depositAssets(key, amount0, amount1);
        return liquidity;
    }

    function removeLiquidity(PoolKey calldata key, uint256 liquidity) external payable returns (uint256, uint256) {
        PoolId poolId = key.toId();
        if (!isReapPool[poolId]) revert NotReapPool();

        uint256 lpTokenId = _getLpTokenId(key);
        uint256 balance = balanceOf(msg.sender, lpTokenId);
        if (balance < liquidity) revert InsufficientAmount();

        uint256 totalShares0 = poolIdToMorphoShares[poolId][key.currency0];
        uint256 totalShares1 = poolIdToMorphoShares[poolId][key.currency1];

        uint256 userShares0 = totalShares0 * liquidity / lpTokenTotalSupply[lpTokenId];
        uint256 userShares1 = totalShares1 * liquidity / lpTokenTotalSupply[lpTokenId];

        lpTokenTotalSupply[lpTokenId] -= liquidity;
        _burn(msg.sender, lpTokenId, liquidity);

        // Withdraw from Morpho Vault
        return _redeemShares(key, userShares0, userShares1, msg.sender);
    }

    // --------------------- HELPER FUNCTIONS ---------------------
    function _addLiquidityToPool(PoolKey calldata key, uint256 amount0, uint256 amount1)
        internal
        returns (uint256, uint256)
    {
        PoolId poolId = key.toId();
        bytes memory actions =
            abi.encodePacked(bytes1(uint8(Actions.MINT_POSITION)), bytes1(uint8(Actions.SETTLE_PAIR)));
        bytes[] memory modifyLiquidityParams = new bytes[](2);
        int24 tickLower = TickMath.minUsableTick(key.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(key.tickSpacing);

        (uint160 currentSqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            currentSqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );

        modifyLiquidityParams[0] = abi.encode(
            key,
            tickLower,
            tickUpper,
            liquidity, // Amount of liquidity to mint
            amount0, // Maximum amount of token0 to use
            amount1, // Maximum amount of token1 to use
            address(this), // Who receives the NFT
            "" // No hook data needed
        );

        modifyLiquidityParams[1] = abi.encode(
            key.currency0, // First token to settle
            key.currency1 // Second token to settle
        );

        uint256 posmTokenId = posm.nextTokenId();
        poolIdToPosMTokenId[poolId] = posmTokenId;

        uint256 balance0Before = key.currency0.balanceOfSelf();
        uint256 balance1Before = key.currency1.balanceOfSelf();

        permit2.approve(Currency.unwrap(key.currency1), address(posm), uint160(amount1), 0);
        if (!key.currency0.isAddressZero()) {
            permit2.approve(Currency.unwrap(key.currency0), address(posm), uint160(amount0), 0);
            posm.modifyLiquiditiesWithoutUnlock(actions, modifyLiquidityParams);
        } else {
            posm.modifyLiquiditiesWithoutUnlock{value: amount0}(actions, modifyLiquidityParams);
        }

        uint256 balance0After = key.currency0.balanceOfSelf();
        uint256 balance1After = key.currency1.balanceOfSelf();

        uint256 amount0Added = balance0Before - balance0After;
        uint256 amount1Added = balance1Before - balance1After;
        return (amount0Added, amount1Added);
    }

    function _removeLiquidityFromPool(PoolKey calldata key) internal returns (uint256, uint256) {
        bytes memory actions = abi.encodePacked(bytes1(uint8(Actions.BURN_POSITION)), bytes1(uint8(Actions.TAKE_PAIR)));
        bytes[] memory params = new bytes[](2);
        uint256 posmTokenId = poolIdToPosMTokenId[key.toId()];

        // Parameters for BURN_POSITION
        params[0] = abi.encode(
            posmTokenId, // Position to burn
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

        uint256 balance0Before = key.currency0.balanceOfSelf();
        uint256 balance1Before = key.currency1.balanceOfSelf();
        posm.modifyLiquiditiesWithoutUnlock(actions, params);
        uint256 balance0After = key.currency0.balanceOfSelf();
        uint256 balance1After = key.currency1.balanceOfSelf();

        uint256 amount0Withdrawn = balance0After - balance0Before;
        uint256 amount1Withdrawn = balance1After - balance1Before;

        delete poolIdToPosMTokenId[key.toId()];

        return (amount0Withdrawn, amount1Withdrawn);
    }

    function _depositAssets(PoolKey calldata key, uint256 amount0, uint256 amount1) internal {
        PoolId poolId = key.toId();
        (address vault0, address vault1) = (_getMorphoVault(key.currency0), _getMorphoVault(key.currency1));
        if (key.currency0.isAddressZero()) {
            weth.approve(vault0, amount0);
        } else {
            IERC20(Currency.unwrap(key.currency0)).approve(vault0, amount0);
        }
        IERC20(Currency.unwrap(key.currency1)).approve(vault1, amount1);
        uint256 shares0 = IMetaMorpho(vault0).deposit(amount0, address(this));
        uint256 shares1 = IMetaMorpho(vault1).deposit(amount1, address(this));
        poolIdToMorphoShares[poolId][key.currency0] += shares0;
        poolIdToMorphoShares[poolId][key.currency1] += shares1;
    }

    function _redeemShares(PoolKey calldata key, uint256 shares0, uint256 shares1, address receiver)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        PoolId poolId = key.toId();
        (address vault0, address vault1) = (_getMorphoVault(key.currency0), _getMorphoVault(key.currency1));
        if (key.currency0.isAddressZero()) {
            amount0 = IMetaMorpho(vault0).redeem(shares0, address(this), address(this));
            weth.withdraw(amount0);
            if (receiver != address(this)) {
                (bool success,) = payable(receiver).call{value: amount0}("");
                if (!success) revert TransferFailed();
            }
        } else {
            amount0 = IMetaMorpho(vault0).redeem(shares0, receiver, address(this));
        }
        amount1 = IMetaMorpho(vault1).redeem(shares1, receiver, address(this));
        poolIdToMorphoShares[poolId][key.currency0] -= shares0;
        poolIdToMorphoShares[poolId][key.currency1] -= shares1;
    }

    function _getMorphoVault(Currency currency) internal view returns (address) {
        address vaultAddress;
        if (currency.isAddressZero()) {
            vaultAddress = currencyToMorphoVault[Currency.wrap(address(weth))];
        } else {
            vaultAddress = currencyToMorphoVault[currency];
        }

        if (vaultAddress == address(0)) {
            revert UnsupportedCurrency(currency);
        }

        return vaultAddress;
    }

    function _getMorphoBalances(PoolKey calldata key) internal view returns (uint256 balance0, uint256 balance1) {
        address vault0 = _getMorphoVault(key.currency0);
        address vault1 = _getMorphoVault(key.currency1);

        uint256 shares0 = poolIdToMorphoShares[key.toId()][key.currency0];
        uint256 shares1 = poolIdToMorphoShares[key.toId()][key.currency1];

        balance0 = IMetaMorpho(vault0).previewRedeem(shares0);
        balance1 = IMetaMorpho(vault1).previewRedeem(shares1);
        return (balance0, balance1);
    }

    function _getAmountsToAdd(uint256 amount0Desired, uint256 amount1Desired, uint256 balance0, uint256 balance1)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        if (amount0Desired == 0) revert InsufficientAmount();
        if (amount1Desired == 0) revert InsufficientAmount();

        if (balance0 == 0 && balance1 == 0) {
            amount0 = amount0Desired;
            amount1 = amount1Desired;
        } else {
            uint256 amount1Optimal = Math.mulDiv(amount0Desired, balance1, balance0);
            if (amount1Optimal <= amount1Desired) {
                amount0 = amount0Desired;
                amount1 = amount1Optimal;
            } else {
                uint256 amount0Optimal = Math.mulDiv(amount1Desired, balance0, balance1);
                amount0 = amount0Optimal;
                amount1 = amount1Desired;
            }
        }
    }

    function _getLiquidityAmount(
        uint256 existingLiquidity,
        uint256 amount0,
        uint256 amount1,
        uint256 balance0,
        uint256 balance1
    ) internal pure returns (uint256) {
        if (existingLiquidity == 0) {
            return Math.sqrt(amount0 * amount1);
        }

        uint256 L_x = Math.mulDiv(existingLiquidity, amount0, balance0);
        uint256 L_y = Math.mulDiv(existingLiquidity, amount1, balance1);
        return Math.min(L_x, L_y);
    }

    function _getLpTokenId(PoolKey calldata key) internal pure returns (uint256) {
        return uint256(PoolId.unwrap(key.toId()));
    }

    // --------------------- OWNER ONLY ---------------------
    function setMorphoVault(Currency currency, address vaultAddress) external onlyOwner {
        currencyToMorphoVault[currency] = vaultAddress;
    }

    function deleteMorphoVault(Currency currency) external onlyOwner {
        delete currencyToMorphoVault[currency];
    }

    function setReapPool(PoolId poolId, bool _isReapPool) external onlyOwner {
        isReapPool[poolId] = _isReapPool;
    }

    receive() external payable {}
}
