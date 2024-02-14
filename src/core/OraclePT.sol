// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "@pendle/contracts/oracles/PendlePtOracleLib.sol";

/**
    @title NoFrame Price Oracle for Pendle PTs
    @notice TO DO
 */
abstract contract OraclePT {
    function pricePTtoAsset(address _market, uint32 _duration) public returns  (uint256) {
        uint256 price = PendlePtOracleLib.getPtToAssetRate(IPMarket(_market), _duration);
        return price;
    }

}
