// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "./OracleChainlink.sol";
import "./OraclePT.sol";

import {Test, console} from "forge-std/Test.sol";

/**
    @title NoFrame Router
    @notice TO DO
 */
contract OraclePTwstETH is OracleChainlink, OraclePT {

    address wstETHtoETH;
    address ETHtoUSD;
    address PTmarket;
    uint32 durationTWAP = 1;

    constructor(address _wstETHtoETH, address _ETHtoUSD, address _ptMarket) {
        wstETHtoETH = _wstETHtoETH;
        ETHtoUSD = _ETHtoUSD;
        PTmarket = _ptMarket;
        priceChainlink(wstETHtoETH);
        priceChainlink(ETHtoUSD);
    }

    function price() public returns (uint256) {
        return priceChainlink(wstETHtoETH) * priceChainlink(ETHtoUSD) * pricePTtoAsset(PTmarket, durationTWAP) / 10**46;
    }
}
