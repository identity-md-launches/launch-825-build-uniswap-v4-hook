// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Paper} from "../src/Paper.sol";
import {PaperDeployment} from "../src/PaperDeployment.sol";

contract PaperTest is Test {
    function test_metadataSupplyAndTransfer() public {
        Paper token = new Paper();
        assertEq(token.name(), "paper");
        assertEq(token.symbol(), "paper");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
        token.transfer(address(123), 5 ether);
        assertEq(token.balanceOf(address(123)), 5 ether);
        assertEq(token.balanceOf(address(this)), 1e27 - 5 ether);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_noMintOrAdminEvenForDeployer() public {
        Paper token = new Paper();
        (bool ok,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", address(this), 1));
        assertFalse(ok);
        (ok,) = address(token).call(abi.encodeWithSignature("transferOwnership(address)", address(123)));
        assertFalse(ok);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_allowanceAndBalanceFailures() public {
        Paper token = new Paper();
        vm.prank(address(123));
        vm.expectRevert();
        token.transfer(address(this), 1);
        vm.prank(address(123));
        vm.expectRevert();
        token.transferFrom(address(this), address(123), 1);
        token.approve(address(123), 10);
        vm.prank(address(123));
        token.transferFrom(address(this), address(123), 10);
        assertEq(token.allowance(address(this), address(123)), 0);
    }

    function test_deploymentAllocatesEightyPercentAndRemainder() public {
        PaperDeployment deployment = new PaperDeployment();
        Paper token = deployment.deployToken();
        assertEq(token.balanceOf(address(this)), 800_000_000 ether);
        assertEq(token.balanceOf(deployment.REMAINDER_TO()), 200_000_000 ether);
        assertEq(token.balanceOf(address(deployment)), 0);
    }
}
