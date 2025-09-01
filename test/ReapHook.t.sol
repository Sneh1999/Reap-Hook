// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IUniversalRouter} from "src/interfaces/IUniversalRouter.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {IV4Router} from "v4-periphery/src/interfaces/IV4Router.sol";

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HookMiner} from "./utils/HookMiner.sol";

import "../src/ReapHook.sol";

import "forge-std/Test.sol";

contract ReapHookTest is Test, ERC1155Holder {
    // Tokens
    address WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // Uniswap
    address POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;

    // Morpho
    address VAULT_WETH = 0x2371e134e3455e0593363cBF89d3b6cf53740618;
    address VAULT_USDC = 0x8eB67A509616cd6A7c1B3c8C21D48FF57df3d458;

    // Utils
    address CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address USDC_WHALE = 0x55FE002aefF02F77364de339a1292923A15844B8;

    // Users
    address ALICE = address(1);
    address BOB = address(2);
    address CHARLIE = address(3);

    // Custom
    ReapHook reapHook;
    PoolKey key;

    function setUp() public {
        vm.createSelectFork("mainnet");

        Currency currency0 = Currency.wrap(address(0));
        Currency currency1 = Currency.wrap(USDC);

        uint160 flags = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG;
        bytes memory creationCode = type(ReapHook).creationCode;
        bytes memory constructorArgs = abi.encode(POOL_MANAGER, POSITION_MANAGER, PERMIT2, WETH);
        (address hookAddress, bytes32 salt) = HookMiner.find(address(this), flags, creationCode, constructorArgs);

        reapHook = new ReapHook{salt: salt}(
            IPoolManager(POOL_MANAGER), IPositionManager(POSITION_MANAGER), IPermit2(PERMIT2), IWETH9(WETH)
        );
        require(address(reapHook) == hookAddress, "hook address mismatch");

        key = PoolKey({currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 60, hooks: reapHook});

        /// sqrtPriceX96 = floor(sqrt(B / A) * 2 ** 96) where A and B are the currency reserves
        /// 1 ETH = 5000 USDC => A = 1e18, B = 5000e6
        /// sqrtPriceX96 = floor(sqrt( 5000e6/1e18) * 2 ** 96) = 5.602e24
        IPoolManager(POOL_MANAGER).initialize(key, 5.602e24);

        reapHook.setReapPool(key.toId(), true);
        reapHook.setMorphoVault(Currency.wrap(WETH), VAULT_WETH);
        reapHook.setMorphoVault(currency1, VAULT_USDC);
    }

    function test_Add_Remove_Liquidity() public {
        uint256 aliceLiquidity = _addLiquidity(ALICE, 1 ether, 5000e6);
        uint256 bobLiquidity = _addLiquidity(BOB, 9 ether, 9 * 5000e6);

        (uint256 aliceAmount0, uint256 aliceAmount1) = _removeLiquidity(ALICE, aliceLiquidity);
        assertApproxEqAbs(aliceAmount0, 1 ether, 1);
        assertApproxEqAbs(aliceAmount1, 5000e6, 1);

        (uint256 bobAmount0, uint256 bobAmount1) = _removeLiquidity(BOB, bobLiquidity);
        assertApproxEqAbs(bobAmount0, 9 ether, 10);
        assertApproxEqAbs(bobAmount1, 9 * 5000e6, 10);
    }

    function test_Swap_Via_Reap() public {
        uint256 aliceLiquidity = _addLiquidity(ALICE, 100 ether, 5000 * 100 * 1e6);
        uint256 bobLiquidity = _addLiquidity(BOB, 900 ether, 5000 * 900 * 1e6);

        uint256 amountIn = 1 ether;
        vm.deal(CHARLIE, amountIn);
        bytes memory actions = abi.encodePacked(
            bytes1(uint8(Actions.SWAP_EXACT_IN_SINGLE)),
            bytes1(uint8(Actions.SETTLE_ALL)),
            bytes1(uint8(Actions.TAKE_ALL))
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: uint128(amountIn),
                amountOutMinimum: 0,
                hookData: ""
            })
        );
        params[1] = abi.encode(key.currency0, amountIn);
        params[2] = abi.encode(key.currency1, 0);

        // The UniversalRouter `execute` envelope for V4:
        // commands = single byte 0x10 (V4_SWAP)
        // inputs[0] = abi.encode(actions, v4Params)
        bytes memory commands = hex"10";
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        uint256 deadline = block.timestamp + 300;

        uint256 usdcBefore = IERC20(USDC).balanceOf(CHARLIE);
        vm.prank(CHARLIE);
        IUniversalRouter(UNIVERSAL_ROUTER).execute{value: amountIn}(commands, inputs, deadline);
        uint256 usdcAfter = IERC20(USDC).balanceOf(CHARLIE);
        uint256 usdcReceived = usdcAfter - usdcBefore;

        assertApproxEqAbs(usdcReceived, 5000e6, 50e6);

        (uint256 aliceAmount0, uint256 aliceAmount1) = _removeLiquidity(ALICE, aliceLiquidity);
        (uint256 bobAmount0, uint256 bobAmount1) = _removeLiquidity(BOB, bobLiquidity);
        assertGt(aliceAmount0, 100 ether);
        assertLt(aliceAmount1, 5000 * 100 * 1e6);
        assertGt(bobAmount0, 900 ether);
        assertLt(bobAmount1, 5000 * 900 * 1e6);
    }

    function _addLiquidity(address who, uint256 amount0, uint256 amount1) internal returns (uint256) {
        vm.deal(who, amount0);
        _mintUSDC(who, amount1);

        vm.startPrank(who);
        IERC20(USDC).approve(address(reapHook), amount1);
        uint256 liquidity = reapHook.addLiquidity{value: amount0}(key, amount0, amount1);
        vm.stopPrank();
        return liquidity;
    }

    function _removeLiquidity(address who, uint256 liquidity) internal returns (uint256, uint256) {
        vm.startPrank(who);
        (uint256 amount0, uint256 amount1) = reapHook.removeLiquidity(key, liquidity);
        vm.stopPrank();
        return (amount0, amount1);
    }

    function _mintUSDC(address to, uint256 amount) internal {
        vm.prank(USDC_WHALE);
        IERC20(USDC).transfer(to, amount);
    }
}
