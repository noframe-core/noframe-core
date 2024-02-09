// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";

import {SharedDeploy} from "./SharedDeploy.t.sol";
import { IERC20, ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {MarketCore} from "src/core/MarketCore.sol";

contract DeployTest is SharedDeploy {

    function testDeploy() public {

        address collateral = address(govToken);
        mock_chainlink.setPrice(10000000 * 10**18);
        mock_chainlink.setPrice(10000000 * 10**18);
        mock_chainlink.setPrice(10000000 * 10**18);
        mock_tellor.setPrice(10**18);
        

        uint256 _mcr = 1100000000000000000;
        uint256 _ccr = 1500000000000000000;
        uint256 minuteDecayFactor = 999037758833783000;
        uint256 redemptionFeeFloor = 5 * 10**15;
        uint256 borrowingFeeFloor = 5 * 10**15;
        uint256 maxBorrowingFee = 5 * 10**16;
        uint256 interestRate = 0;
        uint256 maxDebt = 10 ** 30;

        vm.prank(address(adminVoting));
        factory.deployNewInstance(
            address(collateral), 
            _mcr,
            _ccr,
            minuteDecayFactor,
            redemptionFeeFloor,
            borrowingFeeFloor,
            maxBorrowingFee,
            interestRate,
            maxDebt
            );
        
        MarketCore market = MarketCore(address(factory.getTroveManager(address(collateral))));
        
        address user = address(22);
        deal(collateral, user, 10000 * 10**18);
        vm.prank(user);
        IERC20(collateral).approve(address(borrowerOperations), 10000 * 10**18);
        vm.prank(user);
        borrowerOperations.openTrove(IERC20(collateral), user, 10**18, 10000 * 10**18, 1800 * 10**18 + 1, address(0), address(0));

        console.log(stablecoin.balanceOf(user));
        
    }
}
