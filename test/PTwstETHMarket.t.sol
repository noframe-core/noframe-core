// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";

import {SharedDeploy} from "./SharedDeploy.t.sol";
import { IERC20, ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {MarketCore} from "src/core/MarketCore.sol";
import {OraclePTwstETH} from "src/core/OraclePTwstETH.sol";

contract DeployTest is SharedDeploy {

    address collateral = 0x1255638EFeca62e12E344E0b6B22ea853eC6e2c7; // PT

        address wstethtoeth = 0xb523AE262D20A936BC152e6023996e46FDC2A95D;
        address ethtousd = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
        address ptmarket = 0x08a152834de126d2ef83D612ff36e4523FD0017F;

        uint256 _mcr = 1100000000000000000;
        uint256 _ccr = 1500000000000000000;
        uint256 minuteDecayFactor = 999037758833783000;
        uint256 redemptionFeeFloor = 5 * 10**15;
        uint256 borrowingFeeFloor = 5 * 10**15;
        uint256 maxBorrowingFee = 5 * 10**16;
        uint256 interestRate = 0;
        uint256 maxDebt = 10 ** 30;

    function testDeploy() public {

        OraclePTwstETH oracle = new OraclePTwstETH(wstethtoeth, ethtousd, ptmarket);
        
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
        vm.prank(address(adminVoting));
        oracleRouter.setOracle(collateral, address(market), address(oracle));
        
        address user = address(22);
        deal(collateral, user, 1 * 10**18);
        vm.prank(user);
        IERC20(collateral).approve(address(borrowerOperations), 1 * 10**18);
        vm.prank(user);
        borrowerOperations.openTrove(IERC20(collateral), user, 10**18, 1 * 10**18, 2300 * 10**18, address(0), address(0));
        console.log(stablecoin.balanceOf(user));
    }
}
