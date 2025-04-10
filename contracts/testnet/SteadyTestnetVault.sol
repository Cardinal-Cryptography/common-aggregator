// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

interface MintableERC20 is IERC20 {
    function mint(address to, uint256 amount) external;
}

/// @title ERC4626 testnet vault with fixed APR.
/// @notice This vault is designed to be used on testnets only.
/// @dev This contract should have permissions to mint `_asset`. For safety,
/// the maximum amount of assets that can be minted in one call is limited to 10**64.
/// Additionally, the contract can be paused to stop minting tokens.
contract SteadyTestnetVault is Ownable2Step, ERC4626, Pausable {
    using Math for uint256;

    uint256 lastUpdateTimestamp;
    uint256 aprBps;
    uint256 assetsHeld;

    constructor(MintableERC20 _asset, string memory _name, string memory _symbol, uint256 _aprBps)
        Ownable(msg.sender)
        ERC4626(_asset)
        ERC20(_name, _symbol)
        Pausable()
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
        if (paused()) {
            return assetsHeld;
        }
        uint256 timeElapsed = block.timestamp - lastUpdateTimestamp;
        uint256 mintAmount = assetsHeld.mulDiv(timeElapsed * aprBps, 10_000 * 365 days);
        uint256 cappedMintAmount = Math.min(mintAmount, 10 ** 64);
        return assetsHeld + cappedMintAmount;
    }

    /// @notice Pauses minting tokens.
    /// @dev This will "lose" all earnings that preview functions have seen since the previous update,
    /// as the next update won't mint any new tokens at all.
    function pause() public onlyOwner {
        _pause();
    }

    function unpause() public onlyOwner {
        _unpause();
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }
}
