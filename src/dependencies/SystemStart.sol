// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "../interfaces/IAddressProvider.sol";

/**
    @title NoFrame System Start Time
    @dev Provides a unified `startTime` and `getWeek`, used for emissions.
 */
contract SystemStart {
    uint256 immutable startTime;

    constructor(address prismaCore) {
        startTime = IAddressProvider(prismaCore).startTime();
    }

    function getWeek() public view returns (uint256 week) {
        return (block.timestamp - startTime) / 1 weeks;
    }
}
