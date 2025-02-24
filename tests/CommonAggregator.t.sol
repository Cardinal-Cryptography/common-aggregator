// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {CommonAggregator} from "contracts/CommonAggregator.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC4626Mock} from "tests/mock/ERC4626Mock.sol";
import {ERC20Mock} from "tests/mock/ERC20Mock.sol";


contract CommonAggregatorTest is Test {
    CommonAggregator commonAggregator;
    address owner = address(0x123);

    function setUp() public {
        IERC20 asset = new ERC20Mock();

        CommonAggregator implementation = new CommonAggregator();
        IERC4626[] memory vaults = new IERC4626[](2);
        vaults[0] = new ERC4626Mock(address(asset));
        vaults[1] = new ERC4626Mock(address(asset));

        bytes memory initializeData = abi.encodeWithSelector(CommonAggregator.initialize.selector, owner, asset, vaults);

        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initializeData);
        commonAggregator = CommonAggregator(address(proxy));
    }

    function testRoleGranting() public {
        assertTrue(commonAggregator.hasRole(commonAggregator.DEFAULT_ADMIN_ROLE(), owner));
        assertTrue(commonAggregator.hasRole(commonAggregator.OWNER(), owner));

        address otherAccount = address(0x456);
        assertFalse(commonAggregator.hasRole(commonAggregator.OWNER(), otherAccount));
        assertFalse(commonAggregator.hasRole(commonAggregator.MANAGER(), otherAccount));

        vm.prank(owner);
        commonAggregator.grantRole(keccak256("MANAGER"), otherAccount);
        assertTrue(commonAggregator.hasRole(commonAggregator.MANAGER(), otherAccount));
    }

    // Initializer

    function testWrongAssetInInitializer() public {
        IERC20 asset = new ERC20Mock();
        CommonAggregator implementation = new CommonAggregator();
        IERC4626[] memory vaults = new IERC4626[](1);
        vaults[0] = new ERC4626Mock(address(asset));

        bytes memory initializeData = abi.encodeWithSelector(CommonAggregator.initialize.selector, owner, new ERC20Mock(), vaults);

        vm.expectRevert();
        new ERC1967Proxy(address(implementation), initializeData);
    }

    function testMismatchingAssetInVaultsInInitializer() public {
        IERC20 asset = new ERC20Mock();
        CommonAggregator implementation = new CommonAggregator();
        IERC4626[] memory vaults = new IERC4626[](2);
        vaults[0] = new ERC4626Mock(address(asset));
        vaults[1] = new ERC4626Mock(address(new ERC20Mock()));

        bytes memory initializeData = abi.encodeWithSelector(CommonAggregator.initialize.selector, owner, asset, vaults);

        vm.expectRevert();
        new ERC1967Proxy(address(implementation), initializeData);
    }

    function testSameVaultCantBeTwiceInInitializer() public {
        IERC20 asset = new ERC20Mock();
        CommonAggregator implementation = new CommonAggregator();
        IERC4626[] memory vaults = new IERC4626[](2);
        vaults[0] = new ERC4626Mock(address(asset));
        vaults[1] = vaults[0];

        bytes memory initializeData = abi.encodeWithSelector(CommonAggregator.initialize.selector, owner, asset, vaults);

        vm.expectRevert();
        new ERC1967Proxy(address(implementation), initializeData);
    }
}
