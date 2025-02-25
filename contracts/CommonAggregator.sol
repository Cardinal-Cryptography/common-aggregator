// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {ICommonAggregator} from "./interfaces/ICommonAggregator.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IERC20, ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {
    IERC4626,
    ERC4626Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import "./RewardBuffer.sol";

contract CommonAggregator is ICommonAggregator, UUPSUpgradeable, AccessControlUpgradeable, ERC4626Upgradeable {
    using RewardBuffer for RewardBuffer.Buffer;
    using Math for uint256;

    bytes32 public constant OWNER = keccak256("OWNER");
    bytes32 public constant MANAGER = keccak256("MANAGER");
    bytes32 public constant REBALANCER = keccak256("REBALANCER");
    bytes32 public constant GUARDIAN = keccak256("GUARDIAN");

    uint256 public constant MAX_VAULTS = 5;
    uint256 public constant MAX_BPS = 10000;
    uint256 public constant MAX_PROTOCOL_FEE_BPS = 5000; // 50%

    /// @custom:storage-location erc7201:common.storage.aggregator
    struct AggregatorStorage {
        RewardBuffer.Buffer rewardBuffer;
        IERC4626[] vaults; // Both for iterating and a fallback queue.
        mapping(address vault => uint256 limit) allocationLimit;
        uint256 protocolFeeBps;
        address protocolFeeReceiver;
    }

    // keccak256(abi.encode(uint256(keccak256("common.storage.aggregator")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant AGGREGATOR_STORAGE_LOCATION =
        0x1344fc1d9208ab003bf22755fd527b5337aabe73460e3f8720ef6cfd49b61d00;

    function _getAggregatorStorage() private pure returns (AggregatorStorage storage $) {
        assembly {
            $.slot := AGGREGATOR_STORAGE_LOCATION
        }
    }

    function initialize(address owner, IERC20Metadata asset, IERC4626[] memory vaults) public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ERC20_init(string.concat("Common-Aggregator-", asset.name(), "-v1"), string.concat("ca", asset.symbol()));
        __ERC4626_init(asset);

        _grantRole(DEFAULT_ADMIN_ROLE, owner);
        _grantRole(OWNER, owner);

        AggregatorStorage storage $ = _getAggregatorStorage();

        for (uint256 i = 0; i < vaults.length; i++) {
            _ensureVaultCanBeAdded(vaults[i]);
            $.vaults.push(vaults[i]);
            $.allocationLimit[address(vaults[i])] = MAX_BPS;
        }

        $.protocolFeeBps = 0;
        $.protocolFeeReceiver = address(0);
    }

    function _ensureVaultCanBeAdded(IERC4626 vault) private view {
        require(address(vault) != address(0), "CommonAggregator: zero address");
        require(vault.asset() == asset(), "CommonAggregator: wrong asset");

        AggregatorStorage storage $ = _getAggregatorStorage();
        require($.vaults.length < MAX_VAULTS, "CommonAggregator: too many vaults");
        for (uint256 i = 0; i < $.vaults.length; i++) {
            require(address($.vaults[i]) != address(vault), "CommonAggregator: vault already exists");
        }
    }

    // ----- ERC4626 -----

    function deposit(uint256 _amount, address _account)
        public
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256)
    {
        updateHoldingsState();
        uint256 result = super.deposit(_amount, _account);
        updateHoldingsState();
        return result;
    }

    function mint(uint256 _shares, address _account) public override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        updateHoldingsState();
        uint256 result = super.mint(_shares, _account);
        updateHoldingsState();
        return result;
    }

    function withdraw(uint256 _amount, address _account, address _owner)
        public
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256)
    {
        updateHoldingsState();
        uint256 result = super.withdraw(_amount, _account, _owner);
        updateHoldingsState();
        return result;
    }

    function redeem(uint256 _shares, address _account, address _owner)
        public
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256)
    {
        updateHoldingsState();
        uint256 result = super.redeem(_shares, _account, _owner);
        updateHoldingsState();
        return result;
    }

    // ----- Reporting -----

    function updateHoldingsState() public override {
        AggregatorStorage storage $ = _getAggregatorStorage();
        uint256 oldCachedAssets = $.rewardBuffer._getAssetsCached();
        uint256 newAssets = _totalAssetsNotCached();

        if (oldCachedAssets == 0) {
            if (newAssets == 0) {
                return;
            }
            //Instantly unlock all rewards.
            $.rewardBuffer = RewardBuffer._newBuffer(newAssets);
        } else {
            (uint256 sharesToBurn, uint256 sharesToMint) = $.rewardBuffer._updateBuffer(newAssets, totalSupply());
            if (sharesToMint > 0) {
                _mint(address(this), sharesToMint);
            }
            if (sharesToBurn > 0) {
                uint256 protocolFeeShares = sharesToBurn.mulDiv($.protocolFeeBps, MAX_BPS, Math.Rounding.Ceil);
                _burn(address(this), sharesToBurn - protocolFeeShares);
                _transfer(address(this), $.protocolFeeReceiver, protocolFeeShares);
            }
        }

        emit HoldingsStateUpdated(oldCachedAssets, newAssets);
    }

    /// @notice Preview the holdings state update, without actually updating it.
    /// Returns `totalAssets` and `totalSupply` that there would be after the update.
    function _previewUpdateHoldingsState() internal view returns (uint256 newAssets, uint256 newSupply) {
        AggregatorStorage storage $ = _getAggregatorStorage();
        newAssets = _totalAssetsNotCached();

        if ($.rewardBuffer._getAssetsCached() == 0) {
            return (newAssets, totalSupply());
        }
        (, uint256 sharesToMint, uint256 sharesToBurn) = $.rewardBuffer._simulateBufferUpdate(newAssets, totalSupply());
        uint256 protocolFeeShares = sharesToBurn.mulDiv($.protocolFeeBps, MAX_BPS, Math.Rounding.Ceil);
        return (newAssets, totalSupply() + sharesToMint - sharesToBurn + protocolFeeShares);
    }

    function _totalAssetsNotCached() internal view returns (uint256) {
        AggregatorStorage storage $ = _getAggregatorStorage();

        uint256 assets = IERC20(asset()).balanceOf(address(this));
        for (uint256 i = 0; i < $.vaults.length; i++) {
            IERC4626 vault = $.vaults[i];
            uint256 shares = vault.balanceOf(address(this));
            assets += vault.convertToAssets(shares);
        }
        return assets;
    }

    // ----- Fee management -----

    /// @inheritdoc ICommonAggregator
    function setProtocolFee(uint256 protocolFeeBps) external onlyRole(OWNER) {
        require(protocolFeeBps <= MAX_PROTOCOL_FEE_BPS, "CommonAggregator: protocol fee too high");

        AggregatorStorage storage $ = _getAggregatorStorage();
        uint256 oldProtocolFee = $.protocolFeeBps;

        if (oldProtocolFee == protocolFeeBps) return;
        $.protocolFeeBps = protocolFeeBps;
        emit ProtocolFeeChanged(oldProtocolFee, protocolFeeBps);
    }

    /// @inheritdoc ICommonAggregator
    function setProtocolFeeReceiver(address protocolFeeReceiver) external onlyRole(OWNER) {
        require(protocolFeeReceiver != address(this), "CommonAggregator: self protocol fee receiver");

        AggregatorStorage storage $ = _getAggregatorStorage();
        address oldProtocolFeeReceiver = $.protocolFeeReceiver;

        if (oldProtocolFeeReceiver == protocolFeeReceiver) return;
        $.protocolFeeReceiver = protocolFeeReceiver;
        emit ProtocolFeeReceiverChanged(oldProtocolFeeReceiver, protocolFeeReceiver);
    }

    constructor() {
        _disableInitializers();
    }

    function _authorizeUpgrade(address _newImplementation) internal override onlyRole(OWNER) {}
}
