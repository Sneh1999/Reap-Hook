// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMetaMorpho, MarketAllocation} from "lib/metamorpho/src/interfaces/IMetaMorpho.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ERC1155} from "openzeppelin-contracts/contracts/token/ERC1155/ERC1155.sol";

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
    function transfer(address to, uint256 value) external returns (bool);
    function approve(address spender, uint256 value) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

contract ReapLiquidityRouter is Ownable, ERC1155 {
    IPoolManager public immutable manager;
    address WETH;
    // Mapping from asset address to vault address
    mapping(address => address) public morphoAssetToVault;

    event WithdrawalFromMorphoVault(uint256 amount);
    event MorphoDeposit(uint256 amount, uint256 minted);
    event ReapLPTokenMinted(PoolKey poolKey, Currency currency, uint256 amount);

    constructor(IPoolManager _manager, address _WETH) Ownable(msg.sender) {
        manager = _manager;
        WETH = _WETH;
    }

    function modifyLiquidity(PoolKey memory poolKey, uint256 asset0Amount, uint256 asset1Amount) external payable {
        return _modifyLiquidity(poolKey, msg.sender, asset0Amount, asset1Amount);
    }

    function _modifyLiquidity(PoolKey memory poolKey, address sender, uint256 asset0Amount, uint256 asset1Amount)
        internal
    {
        // Get asset 0 address
        Currency assetCurrency0 = poolKey.currency0;
        address asset0 = Currency.unwrap(assetCurrency0);

        // get asset 1 address
        Currency assetCurrency1 = poolKey.currency1;
        address asset1 = Currency.unwrap(assetCurrency1);
        // Check if a vault address exists for the asset
        address vaultAddressAsset0 = morphoAssetToVault[asset0];
        if (vaultAddressAsset0 == address(0)) {
            revert("ReapLiquidityRouter: No vault address found for asset");
        }

        // Check if a vault address exists for the asset
        address vaultAddressAset1 = morphoAssetToVault[asset1];
        if (vaultAddressAset1 == address(0)) {
            revert("ReapLiquidityRouter: No vault address found for asset");
        }

        // process deposits of both assets
        processAssetDeposit(asset0, asset0Amount, vaultAddressAsset0);
        processAssetDeposit(asset1, asset1Amount, vaultAddressAset1);
    }

    // TODO: also add the functionality to process withdrawals
    function processAssetDeposit(address assetAddress, uint256 amount, address vaultAddress) internal {
        // Check if the address is ETH
        if (assetAddress == address(0)) {
            // Check that msg.value is not 0
            if (amount > msg.value) {
                revert("ReapLiquidityRouter: msg.value is not sufficient to the amount");
            }
            // Now convert ETH to WETH equal to msg.value
            IWETH(WETH).deposit{value: amount}();
            // Approve WETH to Morpho Vault
            IERC20(WETH).approve(vaultAddress, amount);
            // Call depositIntoMorphoVault
            depositIntoMorphoVault(WETH, amount, vaultAddress);
            return;
        }
        // TODO: check what is the significance of bool in wrapped assets
        // Transfer assetAddress to msg.sender
        IERC20(assetAddress).transfer(msg.sender, amount);
        // Give vault the approval
        IERC20(assetAddress).approve(vaultAddress, amount);
        // Call depositIntoMorphoVault
        depositIntoMorphoVault(assetAddress, amount, vaultAddress);

        // Mint reapLPToken
        mintReapLPToken(poolKey, currency, amount);
        emit ReapLPTokenMinted(poolKey, currency, amount);
    }

    function mintReapLPToken(PoolKey memory poolKey, Curreny memory currency, uint256 amount) external {
        uint256 erc1155ID = keccak256(abi.encode(poolKey, currency));
        _mint(msg.sender, erc1155ID, amount, "");
    }

    function burnReapLPToken(PoolKey memory poolKey, Curreny memory currency, uint256 amount) external {
        uint256 erc1155ID = keccak256(abi.encode(poolKey, currency));
        // Check if the user has enough balance
        uint256 balance = balanceOf(msg.sender, erc1155ID);
        if (balance < amount) {
            revert("ReapLiquidityRouter: Not enough balance");
        }
        _burn(msg.sender, erc1155ID, amount);
    }

    // Deposit liquidity into Morpho Vault
    function depositIntoMorphoVault(address assetAddress, uint256 amount, address vaultAddress)
        internal
        returns (uint256)
    {
        uint256 sharedMinted = IMetaMorpho(vaultAddress).deposit(amount, address(this));

        emit MorphoDeposit(amount, sharedMinted);
        return sharedMinted;
    }

    // Withdraw liquidity from Morpho Vault
    function withdrawFromMorphoVault(uint256 amount, address vaultAddress) internal {
        IMetaMorpho(vaultAddress).withdraw(amount, address(this), address(this));
        emit WithdrawalFromMorphoVault(amount);
    }

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
