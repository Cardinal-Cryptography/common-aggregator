// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ERC4626, ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface MintableERC20 is IERC20 {
    function mint(address to, uint256 amount) external;
}

/// @title ERC4626 testnet vault with fixed APR.
/// @notice This vault is designed to be used on testnets only.
/// @dev This contract should have permissions to mint `_asset`. For safety,
/// the maximum amount of assets that can be minted in one call is limited to 10**64.
contract SteadyTestnetVault is Ownable2Step, ERC4626 {
    using Math for uint256;

    uint256 private lastUpdateTimestamp;
    uint256 private aprBps;
    uint256 private assetsHeld;

    constructor(MintableERC20 _asset, string memory _name, string memory _symbol, uint256 _aprBps)
        Ownable(msg.sender)
        ERC4626(_asset)
        ERC20(_name, _symbol)
    {
        aprBps = _aprBps;
        lastUpdateTimestamp = block.timestamp;
        assetsHeld = _asset.balanceOf(address(this));
    }

    function update() public {
        uint256 newTotalAssets = totalAssets();
        if (newTotalAssets >= assetsHeld) {
            MintableERC20(asset()).mint(address(this), newTotalAssets - assetsHeld);
        } else {
            IERC20(asset()).transfer(address(1), assetsHeld - newTotalAssets);
        }
        lastUpdateTimestamp = block.timestamp;
        // take any donations
        assetsHeld = IERC20(asset()).balanceOf(address(this));
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        update();
        shares = super.deposit(assets, receiver);
        assetsHeld += assets;
    }

    function mint(uint256 shares, address receiver) public override returns (uint256 assets) {
        update();
        assets = super.mint(shares, receiver);
        assetsHeld += assets;
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256 shares) {
        update();
        shares = super.withdraw(assets, receiver, owner);
        assetsHeld -= assets;
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256 assets) {
        update();
        assets = super.redeem(shares, receiver, owner);
        assetsHeld -= assets;
    }

    function totalAssets() public view override returns (uint256) {
        uint256 timeElapsed = block.timestamp - lastUpdateTimestamp;
        uint256 mintAmount = assetsHeld.mulDiv(timeElapsed * aprBps, 10_000 * 365 days);
        uint256 cappedMintAmount = Math.min(mintAmount, 10 ** 64);
        return assetsHeld + cappedMintAmount;
    }

    function changeApr(uint256 newAprBps) external onlyOwner {
        update();
        aprBps = newAprBps;
    }

    function getApr() external view returns (uint256) {
        return aprBps;
    }

    function takeAssets(uint256 amount) external onlyOwner {
        SafeERC20.safeTransfer(IERC20(asset()), msg.sender, amount);
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }
}
