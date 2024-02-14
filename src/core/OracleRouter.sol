// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "../interfaces/IOracle.sol";
import "./SharedBase.sol";

/**
    @title NoFrame Router
    @notice TO DO
 */
contract OracleRouter is SharedBase {

    constructor(address _addressProvider) SharedBase(_addressProvider) {
    }

    mapping (address => mapping (address => IOracle)) public oracleFor;

    function setOracle(address _collateral, address _market, address _oracle) public onlyOwner {
        oracleFor[_collateral][_market] = IOracle(_oracle);
    }

    function price(address _collateral, address _market) public returns(uint256) {
        IOracle oracle = oracleFor[_collateral][_market];
        return oracle.price();
    }

}
