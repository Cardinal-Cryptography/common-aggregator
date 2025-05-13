// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC4626, CommonAggregator} from "contracts/CommonAggregator.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626Mock} from "tests/mock/ERC4626Mock.sol";
import {ERC20Mock} from "tests/mock/ERC20Mock.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {setUpAggregator} from "tests/utils.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

error PostTransferHookFailed();

contract ERC20WithHook is ERC20Mock {
    address calledAfter;
    bytes encodedCall;

    constructor() ERC20Mock() {}

    function transfer(address _to, uint256 _amount) public override returns (bool result) {
        result = super.transfer(_to, _amount);
        if (calledAfter != address(0)) {
            (bool success,) = calledAfter.call(encodedCall);
            if (!success) {
                revert PostTransferHookFailed();
            }
        }
    }

    function setPostTransferHook(address _calledAfter, bytes memory _encodedCall) external {
        calledAfter = _calledAfter;
        encodedCall = _encodedCall;
    }
}

contract ReentrancyLockTest is Test {
    function testReentrantLock() public {
        address owner = address(0x123);
        ERC20WithHook asset = new ERC20WithHook();
        IERC4626[] memory vaults = new IERC4626[](1);
        vaults[0] = new ERC4626Mock(address(asset));
        (CommonAggregator commonAggregator,) = setUpAggregator(owner, asset, vaults);

        vm.startPrank(owner);
        asset.mint(address(owner), 10 ** 30);
        asset.approve(address(commonAggregator), 10 ** 30);
        commonAggregator.mint(1000, address(owner));

        asset.setPostTransferHook(address(commonAggregator), abi.encodeCall(CommonAggregator.updateHoldingsState, ()));
        vm.expectRevert(PostTransferHookFailed.selector);
        commonAggregator.emergencyRedeem(1000, address(owner), address(owner));

        asset.setPostTransferHook(
            address(commonAggregator), abi.encodeCall(CommonAggregator.deposit, (1, address(owner)))
        );
        vm.expectRevert(PostTransferHookFailed.selector);
        commonAggregator.emergencyRedeem(1000, address(owner), address(owner));

        asset.setPostTransferHook(address(commonAggregator), abi.encodeCall(CommonAggregator.mint, (1, address(owner))));
        vm.expectRevert(PostTransferHookFailed.selector);
        commonAggregator.emergencyRedeem(1000, address(owner), address(owner));

        asset.setPostTransferHook(
            address(commonAggregator), abi.encodeCall(CommonAggregator.redeem, (1, address(owner), address(owner)))
        );
        vm.expectRevert(PostTransferHookFailed.selector);
        commonAggregator.emergencyRedeem(1000, address(owner), address(owner));

        asset.setPostTransferHook(
            address(commonAggregator), abi.encodeCall(CommonAggregator.withdraw, (1, address(owner), address(owner)))
        );
        vm.expectRevert(PostTransferHookFailed.selector);
        commonAggregator.emergencyRedeem(1000, address(owner), address(owner));

        asset.setPostTransferHook(
            address(commonAggregator),
            abi.encodeCall(CommonAggregator.emergencyRedeem, (1, address(owner), address(owner)))
        );
        vm.expectRevert(PostTransferHookFailed.selector);
        commonAggregator.emergencyRedeem(1000, address(owner), address(owner));

        // This call shouldn't revert
        asset.setPostTransferHook(address(commonAggregator), abi.encodeCall(CommonAggregator.getVaults, ()));
        commonAggregator.emergencyRedeem(1000, address(owner), address(owner));
    }
}
