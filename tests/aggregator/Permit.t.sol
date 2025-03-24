// SPDX-License-Identifier: UNKNOWN
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ICommonAggregator} from "contracts/interfaces/ICommonAggregator.sol";
import {CommonAggregator} from "contracts/CommonAggregator.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC4626Mock} from "tests/mock/ERC4626Mock.sol";
import {ERC20Mock} from "tests/mock/ERC20Mock.sol";
import {MAX_BPS} from "contracts/Math.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract PermitTest is Test {
    using Math for uint256;

    uint256 constant STARTING_TIMESTAMP = 100_000_000;
    uint256 constant VAULT_COUNT = 1;

    CommonAggregator commonAggregator;

    ERC20Mock asset = new ERC20Mock();
    ERC4626Mock[] vaults = new ERC4626Mock[](VAULT_COUNT);

    uint256 alicePrivateKey = 0x456;
    address alice;
    address bob = address(0x654);

    function setUp() public {
        vm.warp(STARTING_TIMESTAMP);
        alice = vm.addr(alicePrivateKey);

        CommonAggregator implementation = new CommonAggregator();

        for (uint256 i = 0; i < VAULT_COUNT; ++i) {
            vaults[i] = new ERC4626Mock(address(asset));
        }

        address owner = address(0x123);
        bytes memory initializeData = abi.encodeWithSelector(CommonAggregator.initialize.selector, owner, asset, vaults);

        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initializeData);
        commonAggregator = CommonAggregator(address(proxy));

        _depositFromAlice();
    }

    function testTransferFromUsingPermit() public {
        uint256 shares = commonAggregator.balanceOf(alice);
        uint256 amount = shares / 2;

        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = _permitOnCommonAggregatorData(alicePrivateKey, bob, amount, deadline);

        vm.prank(bob);
        commonAggregator.permit(alice, bob, amount, deadline, v, r, s);

        vm.prank(bob);
        commonAggregator.transferFrom(alice, bob, amount);

        assertEq(commonAggregator.balanceOf(alice), shares - amount);
        assertEq(commonAggregator.balanceOf(bob), amount);
    }

    function testTransferFromUsingPermitExpiredDeadline() public {
        uint256 shares = commonAggregator.balanceOf(alice);
        uint256 amount = shares / 2;

        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = _permitOnCommonAggregatorData(alicePrivateKey, bob, amount, deadline);

        vm.warp(deadline + 1 days);
        vm.prank(bob);
        vm.expectRevert();
        commonAggregator.permit(alice, bob, amount, deadline, v, r, s);
    }

    function _permitOnCommonAggregatorData(uint256 ownerPrivateKey, address spender, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        address owner = vm.addr(ownerPrivateKey);
        bytes32 domainSeparator = commonAggregator.DOMAIN_SEPARATOR();
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                spender,
                value,
                commonAggregator.nonces(owner),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        return vm.sign(ownerPrivateKey, digest);
    }

    function _depositFromAlice() internal {
        asset.mint(alice, 100);
        vm.prank(alice);
        asset.approve(address(commonAggregator), 100);
        vm.prank(alice);
        commonAggregator.deposit(100, alice);
    }
}
