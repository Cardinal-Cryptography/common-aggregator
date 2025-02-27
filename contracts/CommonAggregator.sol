// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {ICommonAggregator} from "./interfaces/ICommonAggregator.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IERC20, ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {
    IERC4626,
    ERC4626Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MAX_BPS} from "./Math.sol";
import "./RewardBuffer.sol";

contract CommonAggregator is ICommonAggregator, UUPSUpgradeable, AccessControlUpgradeable, ERC4626Upgradeable {
    using RewardBuffer for RewardBuffer.Buffer;
    using Math for uint256;

    bytes32 public constant OWNER = keccak256("OWNER");
    bytes32 public constant MANAGER = keccak256("MANAGER");
    bytes32 public constant REBALANCER = keccak256("REBALANCER");
    bytes32 public constant GUARDIAN = keccak256("GUARDIAN");

    uint256 public constant MAX_VAULTS = 5;
    uint256 public constant MAX_PROTOCOL_FEE_BPS = MAX_BPS / 2;

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
        $.protocolFeeReceiver = address(1);
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

    function _decimalsOffset() internal pure override returns (uint8) {
        return 4;
    }

    /// @inheritdoc IERC4626
    /// @notice Returns cached assets from the last holdings state update.
    function totalAssets() public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        AggregatorStorage storage $ = _getAggregatorStorage();
        return $.rewardBuffer._getAssetsCached();
    }

    /// @inheritdoc IERC4626
    /// @dev Updates holdings state before the preview.
    function previewDeposit(uint256 assets) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        (uint256 newTotalAssets, uint256 newTotalSupply) = _previewUpdateHoldingsState();
        return assets.mulDiv(newTotalSupply + 10 ** _decimalsOffset(), newTotalAssets + 1, Math.Rounding.Floor);
    }

    /// @inheritdoc IERC4626
    /// @dev Updates holdings state before the preview.
    function previewMint(uint256 shares) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        (uint256 newTotalAssets, uint256 newTotalSupply) = _previewUpdateHoldingsState();
        return shares.mulDiv(newTotalAssets + 1, newTotalSupply + 10 ** _decimalsOffset(), Math.Rounding.Ceil);
    }

    /// @inheritdoc IERC4626
    /// @dev Updates holdings state before the preview.
    function previewWithdraw(uint256 assets) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        (uint256 newTotalAssets, uint256 newTotalSupply) = _previewUpdateHoldingsState();
        return assets.mulDiv(newTotalSupply + 10 ** _decimalsOffset(), newTotalAssets + 1, Math.Rounding.Ceil);
    }

    /// @inheritdoc IERC4626
    /// @dev Updates holdings state before the preview.
    function previewRedeem(uint256 shares) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        (uint256 newTotalAssets, uint256 newTotalSupply) = _previewUpdateHoldingsState();
        return shares.mulDiv(newTotalAssets + 1, newTotalSupply + 10 ** _decimalsOffset(), Math.Rounding.Floor);
    }

    /// @inheritdoc IERC4626
    /// @notice Updates holdings state before depositing.
    function deposit(uint256 assets, address account) public override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        updateHoldingsState();
        uint256 shares = super.deposit(assets, account);

        AggregatorStorage storage $ = _getAggregatorStorage();
        $.rewardBuffer._increaseAssets(assets);

        return shares;
    }

    function mint(uint256 shares, address account) public override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        updateHoldingsState();
        uint256 assets = super.mint(shares, account);

        AggregatorStorage storage $ = _getAggregatorStorage();
        $.rewardBuffer._increaseAssets(assets);

        return assets;
    }

    function withdraw(uint256 assets, address account, address owner)
        public
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256)
    {
        updateHoldingsState();
        uint256 shares = super.withdraw(assets, account, owner);

        AggregatorStorage storage $ = _getAggregatorStorage();
        $.rewardBuffer._decreaseAssets(assets);

        return shares;
    }

    function redeem(uint256 shares, address account, address owner)
        public
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256)
    {
        updateHoldingsState();
        uint256 assets = super.redeem(shares, account, owner);

        AggregatorStorage storage $ = _getAggregatorStorage();
        $.rewardBuffer._decreaseAssets(assets);

        return assets;
    }

    // TODO: make sure deposits / withdrawals from protocolReceiver are handled correctly

    // ----- Reporting -----

    /// @notice Updates holdinds state, by reporting on every vault how many assets it has.
    /// Profits are smoothed out by the reward buffer, and ditributed to the holders.
    /// Protocol fee is taken from the profits. Potential losses are first covered by the buffer.
    function updateHoldingsState() public override {
        AggregatorStorage storage $ = _getAggregatorStorage();
        uint256 oldCachedAssets = $.rewardBuffer._getAssetsCached();

        if (oldCachedAssets == 0) {
            // We have to wait for the deposit to happen
            return;
        } else {
            uint256 newAssets = _totalAssetsNotCached();
            (uint256 sharesToMint, uint256 sharesToBurn) =
                $.rewardBuffer._updateBuffer(newAssets, totalSupply(), $.protocolFeeBps);
            if (sharesToMint > 0) {
                uint256 feePartOfMintedShares = sharesToMint.mulDiv($.protocolFeeBps, MAX_BPS, Math.Rounding.Ceil);
                _mint(address(this), sharesToMint - feePartOfMintedShares);
                _mint($.protocolFeeReceiver, feePartOfMintedShares);
            }
            if (sharesToBurn > 0) {
                _burn(address(this), sharesToBurn);
            }
            emit HoldingsStateUpdated(oldCachedAssets, newAssets);
        }
    }

    /// @notice Preview the holdings state update, without actually updating it.
    /// Returns `totalAssets` and `totalSupply` that there would be after the update.
    function _previewUpdateHoldingsState() internal view returns (uint256 newTotalAssets, uint256 newTotalSupply) {
        AggregatorStorage storage $ = _getAggregatorStorage();
        if ($.rewardBuffer._getAssetsCached() == 0) {
            return (0, totalSupply());
        }

        newTotalAssets = _totalAssetsNotCached();
        (uint256 sharesToMint, uint256 sharesToBurn) =
            $.rewardBuffer._simulateBufferUpdate(newTotalAssets, totalSupply(), $.protocolFeeBps);
        return (newTotalAssets, totalSupply() + sharesToMint - sharesToBurn);
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
        require(protocolFeeBps <= MAX_PROTOCOL_FEE_BPS, ProtocolFeeTooHigh());

        AggregatorStorage storage $ = _getAggregatorStorage();
        uint256 oldProtocolFee = $.protocolFeeBps;

        if (oldProtocolFee == protocolFeeBps) return;
        $.protocolFeeBps = protocolFeeBps;
        emit ProtocolFeeChanged(oldProtocolFee, protocolFeeBps);
    }

    /// @inheritdoc ICommonAggregator
    function setProtocolFeeReceiver(address protocolFeeReceiver) external onlyRole(OWNER) {
        require(protocolFeeReceiver != address(this), "CommonAggregator: self protocol fee receiver");
        require(protocolFeeReceiver != address(0), "CommonAggregator: address(0) protocol fee receiver");

        AggregatorStorage storage $ = _getAggregatorStorage();
        address oldProtocolFeeReceiver = $.protocolFeeReceiver;

        if (oldProtocolFeeReceiver == protocolFeeReceiver) return;
        $.protocolFeeReceiver = protocolFeeReceiver;
        emit ProtocolFeeReceiverChanged(oldProtocolFeeReceiver, protocolFeeReceiver);
    }

    constructor() {
        _disableInitializers();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(OWNER) {}
}
