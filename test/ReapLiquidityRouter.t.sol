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

contract ReapLiquidityRouterTest is Test {
    ReapLiquidityRouter router;
    address public vaultAddressWeth = 0x2371e134e3455e0593363cBF89d3b6cf53740618;
    address public assetAddressWeth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address vaultUSDC = 0xdd0f28e19C1780eb6396170735D45153D261490d;
    address CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address usdcWhale = 0x55FE002aefF02F77364de339a1292923A15844B8; // big holder

    // Uniswap Addresses
    address poolManager = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address positionManager = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;

    ReapMorphoIntegration public reapMorphoIntegration;
    PoolKey key;

    function setUp() public {
        vm.createSelectFork("mainnet");

        Currency _currency0 = Currency.wrap(address(0));
        Currency _currency1 = Currency.wrap(usdc);

        uint160 flags = Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG;

        bytes memory creationCode = type(ReapLiquidityRouter).creationCode;
        bytes memory constructorArgs =
            abi.encode(IPoolManager(poolManager), IPositionManager(positionManager), assetAddressWeth);

        (address hookAddress, bytes32 salt) = HookMiner.find(address(this), flags, creationCode, constructorArgs);

        router = new ReapLiquidityRouter{salt: salt}(
            IPoolManager(poolManager), IPositionManager(positionManager), assetAddressWeth
        );

        require(address(router) == hookAddress, "hook address mismatch");

        key = PoolKey({currency0: _currency0, currency1: _currency1, fee: 3000, tickSpacing: 120, hooks: router});
        IPoolManager(poolManager).initialize(key, 79228162514264337593543950336);

        // Add the pool to the router
        router.setIsReapPool(key, true);
        // Now set the morphoVault address
        router.setMorphoAssetToVault(assetAddressWeth, vaultAddressWeth);
        router.setMorphoAssetToVault(usdc, vaultUSDC);
    }

    function testModifyLiquidity() public {
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

        // Check that the given contract has correct number of ERC1155 tokens
        uint256 erc1155USDCID = uint256(keccak256(abi.encode(key, usdc)));
        assertEq(IERC1155(router).balanceOf(thisContract, erc1155USDCID), asset1Amount);

        // Get for eth
        uint256 erc1155WETHID = uint256(keccak256(abi.encode(key, address(0))));
        assertEq(IERC1155(router).balanceOf(thisContract, erc1155WETHID), asset0Amount);
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC1155Receiver.onERC1155Received.selector;
    }
}
