// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IMetaMorpho, MarketAllocation} from "lib/metamorpho/src/interfaces/IMetaMorpho.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IWrapped} from "./interfaces/IWrapped.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

// TODO: create interfaces

contract ReapMorphoIntegration is ERC1155 {
    address WETH;

    event WithdrawalFromMorphoVault(uint256 amount);
    event MorphoDeposit(uint256 amount, uint256 minted);
    event ReapLPTokenMinted(PoolKey poolKey, address asset, uint256 amount);

    // Mapping from asset address to vault address

    mapping(address => address) public morphoAssetToVault;

    constructor(address _WETH) ERC1155("") {
        WETH = _WETH;
    }

    // TODO: also add the functionality to process withdrawals
    function processMorphoAssetDeposit(address assetAddress, uint256 amount, address vaultAddress, address spender)
        internal
        returns (uint256)
    {
        // Check if the address is ETH
        if (assetAddress == address(0)) {
            IWrapped(WETH).deposit{value: amount}();
            // Approve WETH to Morpho Vault
            IERC20(WETH).approve(vaultAddress, amount);
        } else {
            // TODO: check what is the significance of bool in wrapped assets
            // Transfer assetAddress to msg.sender
            // TODO: change this code
            if (spender != address(this)) {
                IERC20(assetAddress).transferFrom(spender, address(this), amount);
            }
            // Give vault the approval
            IERC20(assetAddress).approve(vaultAddress, amount);
        }

        // Call depositIntoMorphoVault
        return depositIntoMorphoVault(amount, vaultAddress);
    }

    function depositIntoMorphoVault(uint256 amount, address vaultAddress) internal returns (uint256) {
        uint256 sharedMinted = IMetaMorpho(vaultAddress).deposit(amount, address(this));
        // TODO: maybe shares minted should equal to the ERC1155 tokens that are minted to the user
        emit MorphoDeposit(amount, sharedMinted);
        return sharedMinted;
    }

    function withdrawFromMorphoVault(uint256 amount, address vaultAddress) internal {
        IMetaMorpho(vaultAddress).withdraw(amount, address(this), address(this));
        emit WithdrawalFromMorphoVault(amount);
    }

    function withdrawAll(address vaultAddress) internal returns (uint256) {
        uint256 shares = IMetaMorpho(vaultAddress).balanceOf(address(this));
        if (shares > 0) {
            IMetaMorpho(vaultAddress).redeem(shares, address(this), address(this));
        }
        return shares;
    }

    function mintReapLPToken(PoolKey memory poolKey, address asset, uint256 amount) internal {
        uint256 erc1155ID = uint256(keccak256(abi.encode(poolKey, asset)));
        _mint(msg.sender, erc1155ID, amount, "");
    }

    function balanceOfReapLPToken(PoolKey memory poolKey, address asset) public view returns (uint256) {
        uint256 erc1155ID = uint256(keccak256(abi.encode(poolKey, asset)));
        return balanceOf(msg.sender, erc1155ID);
    }

    function burnReapLPToken(PoolKey memory poolKey, address asset, uint256 amount) internal {
        uint256 erc1155ID = uint256(keccak256(abi.encode(poolKey, asset)));
        _burn(msg.sender, erc1155ID, amount);
    }
}
