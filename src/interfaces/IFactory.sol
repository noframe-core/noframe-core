// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

interface IFactory {
    function getTroveManager(address collateral) external view returns (address);
}
