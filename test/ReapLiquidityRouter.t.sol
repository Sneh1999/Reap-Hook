// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Vm.sol";
import "forge-std/console.sol";
import "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../src/ReapLiquidityRouter.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IV4Router} from "v4-periphery/src/interfaces/IV4Router.sol";
import {IUniversalRouter} from "src/interfaces/IUniversalRouter.sol";
import {IPermit2} from "lib/permit2/src/interfaces/IPermit2.sol";

contract ReapLiquidityRouterTest is Test {
    ReapLiquidityRouter router;
    address public vaultAddressWeth = 0x2371e134e3455e0593363cBF89d3b6cf53740618;
    address public assetAddressWeth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address vaultUSDC = 0x8eB67A509616cd6A7c1B3c8C21D48FF57df3d458;
    address CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address usdcWhale = 0x55FE002aefF02F77364de339a1292923A15844B8; // big holder
    address universalRouter = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;

    // Uniswap Addresses
    address poolManager = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address positionManager = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    ReapMorphoIntegration public reapMorphoIntegration;
    PoolKey key;

    function setUp() public {
        vm.createSelectFork("mainnet");

        Currency _currency0 = Currency.wrap(address(0));
        Currency _currency1 = Currency.wrap(usdc);

        uint160 flags = Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_INITIALIZE_FLAG;

        bytes memory creationCode = type(ReapLiquidityRouter).creationCode;
        bytes memory constructorArgs = abi.encode(
            IPoolManager(poolManager), IPositionManager(positionManager), IPermit2(permit2), assetAddressWeth
        );

        (address hookAddress, bytes32 salt) = HookMiner.find(address(this), flags, creationCode, constructorArgs);

        router = new ReapLiquidityRouter{salt: salt}(
            IPoolManager(poolManager), IPositionManager(positionManager), IPermit2(permit2), assetAddressWeth
        );

        require(address(router) == hookAddress, "hook address mismatch");

        key = PoolKey({currency0: _currency0, currency1: _currency1, fee: 3000, tickSpacing: 60, hooks: router});
        IPoolManager(poolManager).initialize(key, 79228162514264337593543950336);

        // Add the pool to the router
        router.setIsReapPool(key, true);
        // Now set the morphoVault address
        router.setMorphoAssetToVault(assetAddressWeth, vaultAddressWeth);
        router.setMorphoAssetToVault(usdc, vaultUSDC);
    }

    // function testModifyLiquidity() public {
    //     vm.deal(address(this), 100 ether);

    //     uint256 asset1Amount = 1000e6; // 1000 USDC (6 decimals)

    //     address thisContract = address(this);
    //     vm.prank(usdcWhale);
    //     IERC20(usdc).transfer(thisContract, asset1Amount);
    //     vm.stopPrank();

    //     assertEq(IERC20(usdc).balanceOf(thisContract), asset1Amount);

    //     uint256 asset0Amount = 1 ether;
    //     // Give approval of usdc to the router
    //     IERC20(usdc).approve(address(router), asset1Amount);

    //     router.modifyLiquidity{value: asset0Amount}(key, asset0Amount, asset1Amount);

    //     // Check that the given contract has correct number of ERC1155 tokens
    //     uint256 erc1155USDCID = uint256(keccak256(abi.encode(key, usdc)));
    //     assertEq(IERC1155(router).balanceOf(thisContract, erc1155USDCID), asset1Amount);

    //     // Get for eth
    //     uint256 erc1155WETHID = uint256(keccak256(abi.encode(key, address(0))));
    //     assertEq(IERC1155(router).balanceOf(thisContract, erc1155WETHID), asset0Amount);
    // }

    function testSwap() public {
        vm.deal(address(this), 100 ether);
        uint256 asset1Amount = 1000e6; // 1000 USDC (6 decimals)
        address thisContract = address(this);
        vm.prank(usdcWhale);
        IERC20(usdc).transfer(thisContract, asset1Amount);
        vm.stopPrank();

        assertEq(IERC20(usdc).balanceOf(thisContract), asset1Amount);

        uint256 asset0Amount = 1 ether;
        // Give approval of usdc to the router
        IERC20(usdc).approve(address(router), asset1Amount);

        router.modifyLiquidity{value: asset0Amount}(key, asset0Amount, asset1Amount);

        uint128 amountIn = 100 wei;
        uint128 minOut = 0;

        bytes memory actions = abi.encodePacked(
            bytes1(uint8(Actions.SWAP_EXACT_IN_SINGLE)),
            bytes1(uint8(Actions.SETTLE_ALL)),
            bytes1(uint8(Actions.TAKE_ALL))
        );

        bool zeroForOne = true;
        bytes memory hookData = "";

        bytes memory p0 = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                amountOutMinimum: minOut,
                hookData: hookData
            })
        );

        // 2) SETTLE_ALL params: (Currency currencyIn, bool payerIsUser)
        // For native ETH, currency = Currency.wrap(address(0)), payerIsUser = true
        bytes memory p1 = abi.encode(address(0), true);

        // 3) TAKE_ALL params: (Currency currencyOut, address recipient, uint256 minAmount)
        // Take all USDC to `me`. minAmount=0 for “no min” (set >0 in prod).
        bytes memory p2 = abi.encode(Currency.wrap(usdc), address(this), uint256(0));

        bytes[] memory v4Params = new bytes[](3);
        v4Params[0] = p0;
        v4Params[1] = p1;
        v4Params[2] = p2;

        // The UniversalRouter `execute` envelope for V4:
        // commands = single byte 0x10 (V4_SWAP)
        // inputs[0] = abi.encode(actions, v4Params)
        bytes memory commands = hex"10";

        bytes[] memory inputs = new bytes[](1);

        inputs[0] = abi.encode(actions, v4Params);

        // Execute; send ETH as msg.value to fund the swap
        uint256 deadline = block.timestamp + 300;
        uint256 usdcBefore = IERC20(usdc).balanceOf(address(this));

        IUniversalRouter(universalRouter).execute{value: asset0Amount}(commands, inputs, deadline);

        uint256 usdcAfter = IERC20(usdc).balanceOf(address(this));
        assertTrue(usdcAfter > usdcBefore, "no USDC received");
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC1155Receiver.onERC1155Received.selector;
    }
}
