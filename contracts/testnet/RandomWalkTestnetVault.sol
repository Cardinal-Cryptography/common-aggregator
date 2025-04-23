// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ERC4626, ERC20, IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

interface MintableERC20 is IERC20 {
    function mint(address to, uint256 amount) external;
}

error IncorrectMinAprBps();
error IncorrectMaxAprBps();

/// @title ERC4626 testnet vault with random-walk-like changing APR.
/// @notice Let's split time into segments of configured length. For each of these segments,
/// APR delta is randomly chosen between -maxChange and maxChange BPS points, and
/// the new APR is calculated as the previous APR + delta. The new APR is clipped between `minAprBps` and `maxAprBps`,
/// which can be negative. If no update (like deposit, withdraw, or update) has been made for 4 days,
/// the APR stays constant for the rest of the time until updating.
/// @dev This contract should have permissions to mint `_asset`. For safety,
/// the maximum amount of assets that can be minted in one call is limited to 10**64.
/// Additionally, the contract can be paused to stop minting tokens.
contract RandomWalkTestnetVault is Ownable2Step, ERC4626, Pausable {
    using Math for uint256;

    // Internal accounting, so that the amount to mint with update can't be manipulated with a donation just before the update.
    uint256 private assetsHeld;

    uint256 private lastUpdateTimestamp;

    // Invariant: lastAprChangeTimestamp should be at most lastUpdateTimestamp,
    // but not less than it by `TIME_SEGMENT_DURATION` minutes or more.
    uint256 private lastAprChangeTimestamp;
    int256 private aprBps;

    int256 private minAprBps;
    int256 private maxAprBps;
    uint256 private maxAprChangeBps;
    uint256 internal nonceForRandomness;

    uint256 private immutable TIME_SEGMENT_DURATION;

    /// @dev Do not use in production, this is just for testing and its value can be easily manipulated.
    function getPseudoRandomNumber(uint256 nonce) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(nonce)));
    }

    constructor(
        MintableERC20 _asset,
        string memory _name,
        string memory _symbol,
        int256 _startingAprBps,
        int256 _minAprBps,
        int256 _maxAprBps,
        uint256 _maxAprChangeBps,
        uint256 _timeSegmentDuration
    ) Ownable(msg.sender) ERC4626(_asset) ERC20(_name, _symbol) Pausable() {
        aprBps = _startingAprBps;
        lastAprChangeTimestamp = block.timestamp;
        lastUpdateTimestamp = block.timestamp;
        assetsHeld = _asset.balanceOf(address(this));
        minAprBps = _minAprBps;
        maxAprBps = _maxAprBps;
        maxAprChangeBps = _maxAprChangeBps;
        TIME_SEGMENT_DURATION = _timeSegmentDuration;

        require(_minAprBps <= _startingAprBps, IncorrectMinAprBps());
        require(_maxAprBps >= _startingAprBps, IncorrectMaxAprBps());

        nonceForRandomness = uint256(keccak256(abi.encodePacked(address(this))));
    }

    function deposit(uint256 assets, address receiver) public override whenNotPaused returns (uint256 shares) {
        update();
        shares = super.deposit(assets, receiver);
        assetsHeld += assets;
    }

    function mint(uint256 shares, address receiver) public override whenNotPaused returns (uint256 assets) {
        update();
        assets = super.mint(shares, receiver);
        assetsHeld += assets;
    }

    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        whenNotPaused
        returns (uint256 shares)
    {
        update();
        shares = super.withdraw(assets, receiver, owner);
        assetsHeld -= assets;
    }

    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        whenNotPaused
        returns (uint256 assets)
    {
        update();
        assets = super.redeem(shares, receiver, owner);
        assetsHeld -= assets;
    }

    /// @dev Updates the vault state. Calling it shouldn't change the result of any view function.
    function update() public whenNotPaused {
        (uint256 newTotalAssets, int256 newAprBps, uint256 newNonceForRandomness, uint256 aprChangeTimestamp) =
            _simulateUpdate();
        if (newTotalAssets >= assetsHeld) {
            MintableERC20(asset()).mint(address(this), newTotalAssets - assetsHeld);
        } else {
            SafeERC20.safeTransfer(IERC20(asset()), address(1), assetsHeld - newTotalAssets);
        }
        lastUpdateTimestamp = block.timestamp;
        aprBps = newAprBps;
        nonceForRandomness = newNonceForRandomness;
        lastAprChangeTimestamp = aprChangeTimestamp;

        // take any donations
        assetsHeld = IERC20(asset()).balanceOf(address(this));
    }

    function _simulateUpdate()
        public
        view
        returns (uint256 newTotalAssets, int256 newAprBps, uint256 newNonceForRandomness, uint256 aprChangeTimestamp)
    {
        if (paused()) {
            return (assetsHeld, aprBps, nonceForRandomness, lastAprChangeTimestamp);
        }
        uint256 asset = assetsHeld;
        uint256 iters = 0;
        newAprBps = aprBps;
        newNonceForRandomness = nonceForRandomness;
        aprChangeTimestamp = lastAprChangeTimestamp;

        // Loop over time segments, each (except possibly last) of length `TIME_SEGMENT_DURATION` seconds.
        for (uint256 time = lastAprChangeTimestamp; time <= block.timestamp;) {
            uint256 timeSegmentDuration = TIME_SEGMENT_DURATION;
            if (iters > 0) {
                // Change APR by random number from -maxAprChangeBps to maxAprChangeBps percentage points
                int256 r = int256(getPseudoRandomNumber(newNonceForRandomness) % (2 * maxAprChangeBps + 1))
                    - int256(maxAprChangeBps);
                unchecked {
                    ++newNonceForRandomness;
                }
                newAprBps = newAprBps + r;
                if (newAprBps < minAprBps) {
                    newAprBps = minAprBps;
                }
                if (newAprBps > maxAprBps) {
                    newAprBps = maxAprBps;
                }
                aprChangeTimestamp = time;

                if (iters >= 100) {
                    // Too much time from last update. Extend the duration of current time segment
                    // from `TIME_SEGMENT_DURATION` until the end. Keep the APR constant in that time segment.
                    uint256 itersYetExceptThis = (block.timestamp - time) / uint256(TIME_SEGMENT_DURATION);
                    timeSegmentDuration = (TIME_SEGMENT_DURATION) * (itersYetExceptThis + 1);
                    aprChangeTimestamp = time + (timeSegmentDuration - TIME_SEGMENT_DURATION);
                    unchecked {
                        newNonceForRandomness = newNonceForRandomness + itersYetExceptThis;
                    }
                }
            }

            uint256 timeLowerBound = Math.max(time, lastUpdateTimestamp);
            uint256 timeUpperBound = Math.min(block.timestamp, time + timeSegmentDuration);
            if (timeUpperBound < timeLowerBound) {
                revert("timeUpperBound < timeLowerBound");
            }
            uint256 timeElapsed = timeUpperBound - timeLowerBound;
            asset =
                uint256(int256(asset) + (int256(asset) * newAprBps * int256(timeElapsed)) / int256(10_000 * 365 days));

            ++iters;
            time += timeSegmentDuration;
        }

        int256 delta = int256(asset) - int256(assetsHeld);

        if (delta > 10 ** 64) {
            delta = 10 ** 64;
        }
        newTotalAssets = uint256(int256(asset) + int256(delta));
    }

    function totalAssets() public view override returns (uint256) {
        (uint256 newTotalAssets,,,) = _simulateUpdate();
        return newTotalAssets;
    }

    /// @notice Sets minAprBps to a new value. Effective from the next time segment.
    function setMinAprBps(int256 _minAprBps) external onlyOwner {
        update();
        minAprBps = _minAprBps;
    }

    /// @notice Sets minAprBps to a new value. Effective from the next time segment.
    function setMaxAprBps(int256 _maxAprBps) external onlyOwner {
        update();
        maxAprBps = _maxAprBps;
    }

    /// @notice Sets maxAprChangeBps to a new value. Effective from the next time segment.
    function setMaxAprChangeBps(uint256 _maxAprChangeBps) external onlyOwner {
        update();
        maxAprChangeBps = _maxAprChangeBps;
    }

    /// @notice Pauses minting tokens.
    /// @dev This will "lose" all earnings that preview functions have seen since the previous update,
    /// as the next update won't mint any new tokens at all.
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function getAprBps() external view returns (int256) {
        (, int256 newAprBps,,) = _simulateUpdate();
        return newAprBps;
    }

    function getMinAprBps() external view returns (int256) {
        return minAprBps;
    }

    function getMaxAprBps() external view returns (int256) {
        return maxAprBps;
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }
}
