// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {ICommonAggregator} from "contracts/interfaces/ICommonAggregator.sol";
import {CommonAggregator} from "contracts/CommonAggregator.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626Mock} from "tests/mock/ERC4626Mock.sol";
import {ERC20Mock} from "tests/mock/ERC20Mock.sol";

contract CommonAggregatorImpl is CommonAggregator {
    function pullFundsSequential(uint256 assets) external {
        _pullFundsSequential(assets);
    }
}

contract RevertingWithdrawVault is ERC4626Mock {
    constructor(address asset) ERC4626Mock(asset) {}

    function withdraw(uint256, address, address) public pure override returns (uint256) {
        require(false);
        return 0;
    }
}

abstract contract PullSequentialTest is Test {
    CommonAggregatorImpl commonAggregator;
    address owner = address(0x123);
    address alice = address(0x456);
    ERC20Mock asset = new ERC20Mock();
    ERC4626Mock[] vaults;
}

contract HealthyVaultsTest is PullSequentialTest {
    function setUp() public {
        CommonAggregatorImpl implementation = new CommonAggregatorImpl();
        vaults = new ERC4626Mock[](2);
        vaults[0] = new ERC4626Mock(address(asset));
        vaults[1] = new ERC4626Mock(address(asset));

        bytes memory initializeData = abi.encodeWithSelector(CommonAggregator.initialize.selector, owner, asset, vaults);

        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initializeData);
        commonAggregator = CommonAggregatorImpl(address(proxy));
        vm.prank(owner);
    }

    function testPullSequentialAll() public {
        asset.mint(address(vaults[0]), 200);
        asset.mint(address(vaults[1]), 300);
        vaults[0].mint(address(commonAggregator), 200 * 10000);
        vaults[1].mint(address(commonAggregator), 300 * 10000);

        vm.prank(address(commonAggregator));
        commonAggregator.pullFundsSequential(500);

        assertEq(IERC20(asset).balanceOf(address(commonAggregator)), 500);
        assertEq(IERC20(asset).balanceOf(address(vaults[0])), 0);
        assertEq(IERC20(asset).balanceOf(address(vaults[1])), 0);
    }

    function testPullSequentialPartial() public {
        asset.mint(address(vaults[0]), 400);
        asset.mint(address(vaults[1]), 700);
        vaults[0].mint(address(commonAggregator), 400 * 10000);
        vaults[1].mint(address(commonAggregator), 700 * 10000);

        vm.prank(address(commonAggregator));
        commonAggregator.pullFundsSequential(800);

        assertEq(IERC20(asset).balanceOf(address(commonAggregator)), 800);
        assertEq(IERC20(asset).balanceOf(address(vaults[0])), 0);
        assertEq(IERC20(asset).balanceOf(address(vaults[1])), 300);
    }

    function testPullSequentialTooMuch() public {
        asset.mint(address(vaults[0]), 300);
        asset.mint(address(vaults[1]), 400);
        vaults[0].mint(address(commonAggregator), 300 * 10000);
        vaults[1].mint(address(commonAggregator), 400 * 10000);

        vm.prank(address(commonAggregator));
        vm.expectRevert(abi.encodeWithSelector(ICommonAggregator.InsufficientAssetsForWithdrawal.selector, 1));
        commonAggregator.pullFundsSequential(701);

        assertEq(IERC20(asset).balanceOf(address(commonAggregator)), 0);
        assertEq(IERC20(asset).balanceOf(address(vaults[0])), 300);
        assertEq(IERC20(asset).balanceOf(address(vaults[1])), 400);
    }
}

contract UnhealthyVaultTest is PullSequentialTest {
    function setUp() public {
        CommonAggregatorImpl implementation = new CommonAggregatorImpl();
        vaults = new ERC4626Mock[](3);
        vaults[0] = new ERC4626Mock(address(asset));
        vaults[1] = new RevertingWithdrawVault(address(asset));
        vaults[2] = new ERC4626Mock(address(asset));

        bytes memory initializeData = abi.encodeWithSelector(CommonAggregator.initialize.selector, owner, asset, vaults);

        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initializeData);
        commonAggregator = CommonAggregatorImpl(address(proxy));
        vm.prank(owner);
    }

    function testSkipsRevertingVault() public {
        asset.mint(address(vaults[0]), 300);
        asset.mint(address(vaults[1]), 400);
        asset.mint(address(vaults[2]), 200);
        vaults[0].mint(address(commonAggregator), 300 * 10000);
        vaults[1].mint(address(commonAggregator), 400 * 10000);
        vaults[2].mint(address(commonAggregator), 200 * 10000);

        vm.prank(address(commonAggregator));
        vm.expectEmit(true, true, true, true, address(commonAggregator));
        emit ICommonAggregator.VaultWithdrawFailed(vaults[1]);

        commonAggregator.pullFundsSequential(500);

        assertEq(IERC20(asset).balanceOf(address(commonAggregator)), 500);
        assertEq(IERC20(asset).balanceOf(address(vaults[0])), 0);
        assertEq(IERC20(asset).balanceOf(address(vaults[1])), 400);
        assertEq(IERC20(asset).balanceOf(address(vaults[2])), 0);
    }

    function testStopsAfterCollectingFullAmount() public {
        asset.mint(address(vaults[0]), 300);
        vaults[0].mint(address(commonAggregator), 300 * 10000);

        vm.prank(address(commonAggregator));
        vm.recordLogs();

        commonAggregator.pullFundsSequential(300);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 vaultWithdrawFailedEventSignatureHash = keccak256("VaultWithdrawFailed(address)");
        for (uint256 i = 0; i < logs.length; i++) {
            assert(logs[i].topics[0] != vaultWithdrawFailedEventSignatureHash);
        }
        assertEq(IERC20(asset).balanceOf(address(commonAggregator)), 300);
        assertEq(IERC20(asset).balanceOf(address(vaults[0])), 0);
    }
}
