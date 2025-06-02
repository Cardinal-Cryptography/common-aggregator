// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {ShieldedYieldRouter} from "contracts/periphery/ShieldedYieldRouter.sol";
import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "tests/mock/ERC20Mock.sol";
import {ERC4626Mock} from "tests/mock/ERC4626Mock.sol";
import {ShielderMock} from "tests/mock/ShielderMock.sol";

contract CommonAggregatorTest is Test {
    bytes3 MOCK_CONTRACT_VERSION = 0xbadaff;
    ERC20Mock asset = new ERC20Mock();
    ERC4626Mock vault = new ERC4626Mock(address(asset));
    ShielderMock shielder = new ShielderMock();
    ShieldedYieldRouter router = new ShieldedYieldRouter();

    address alice = address(0x456);
    address bob = address(0x654);
    address charlie = address(0x789);

    function setUp() public {
        asset.mint(alice, 1000000);
        asset.mint(bob, 1000000);
    }

    function testYieldShieldNewAccountWorks() public {
        uint256 assetAmount = 1000;
        uint256 shareAmount = assetAmount;
        vm.prank(alice);
        asset.approve(address(router), assetAmount);
        vm.prank(alice);
        router.mintAndShieldWithNewAccount(
            address(shielder), MOCK_CONTRACT_VERSION, address(vault), shareAmount, 0, 0, 0, 0, 0, 0, 0, 0, bytes("")
        );
    }

    function testYieldShieldNewAccountInsufficientApproval() public {
        uint256 assetAmount = 1000;
        uint256 shareAmount = assetAmount;
        vm.prank(alice);
        asset.approve(address(router), 1000);
        vm.prank(alice);
        router.mintAndShieldWithNewAccount(
            address(shielder), MOCK_CONTRACT_VERSION, address(vault), shareAmount, 0, 0, 0, 0, 0, 0, 0, 0, bytes("")
        );

        // donate to vault so the pps increases to 1.5
        vm.prank(alice);
        asset.transfer(address(vault), 500);

        vm.prank(bob);
        asset.approve(address(router), 1000);
        bytes memory expectedError =
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(router), 1000, 1500);
        vm.prank(bob);
        vm.expectRevert(expectedError);
        router.mintAndShieldWithNewAccount(
            address(shielder), MOCK_CONTRACT_VERSION, address(vault), shareAmount, 0, 0, 0, 0, 0, 0, 0, 0, bytes("")
        );
    }

    function testYieldShieldDepositWorks() public {
        uint256 assetAmount = 1000;
        uint256 shareAmount = assetAmount;
        vm.prank(alice);
        asset.approve(address(router), assetAmount);
        vm.prank(alice);
        router.mintAndShield(
            address(shielder), MOCK_CONTRACT_VERSION, address(vault), shareAmount, 0, 0, 0, 0, 0, bytes("")
        );
    }

    function testYieldShieldDepositInsufficientApproval() public {
        uint256 assetAmount = 1000;
        uint256 shareAmount = assetAmount;
        vm.prank(alice);
        asset.approve(address(router), 1000);
        vm.prank(alice);
        router.mintAndShield(
            address(shielder), MOCK_CONTRACT_VERSION, address(vault), shareAmount, 0, 0, 0, 0, 0, bytes("")
        );

        // donate to vault so the pps increases to 1.5
        vm.prank(alice);
        asset.transfer(address(vault), 500);

        vm.prank(bob);
        asset.approve(address(router), 1000);
        bytes memory expectedError =
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(router), 1000, 1500);
        vm.prank(bob);
        vm.expectRevert(expectedError);
        router.mintAndShield(
            address(shielder), MOCK_CONTRACT_VERSION, address(vault), shareAmount, 0, 0, 0, 0, 0, bytes("")
        );
    }

    function testYieldShieldNewAccountShielderReverts() public {
        uint256 assetAmount = 1000;
        uint256 shareAmount = assetAmount;
        shielder.setReverting(true);

        vm.prank(alice);
        asset.approve(address(router), assetAmount);
        vm.prank(alice);
        vm.expectRevert();
        router.mintAndShieldWithNewAccount(
            address(shielder), MOCK_CONTRACT_VERSION, address(vault), shareAmount, 0, 0, 0, 0, 0, 0, 0, 0, bytes("")
        );
    }

    function testYieldShieldShielderReverts() public {
        uint256 assetAmount = 1000;
        uint256 shareAmount = assetAmount;
        shielder.setReverting(true);

        vm.prank(alice);
        asset.approve(address(router), assetAmount);
        vm.prank(alice);
        vm.expectRevert();
        router.mintAndShield(
            address(shielder), MOCK_CONTRACT_VERSION, address(vault), shareAmount, 0, 0, 0, 0, 0, bytes("")
        );
    }
}
