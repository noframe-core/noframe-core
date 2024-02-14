// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

interface IOracleRouter {
    function setOracle(address _collateral, address _market, address _oracle) external;
    function oracleFor(address _collateral, address _market) external returns (address);
}
