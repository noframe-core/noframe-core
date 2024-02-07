// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "../../core/SharedBase.sol";

interface IConvexDepositToken {
    function initialize(uint256 pid) external;
}

/**
    @notice NoFrame Convex Factory
    @title Deploys clones of `ConvexDepositToken` as directed by the NoFrame DAO
 */
contract ConvexFactory is SharedBase {
    using Clones for address;

    address public depositTokenImpl;

    event NewDeployment(uint256 pid, address depositToken);

    constructor(address _addressProvider, address _depositTokenImpl) SharedBase(_addressProvider) {
        depositTokenImpl = _depositTokenImpl;
    }

    /**
        @dev After calling this function, the owner should also call `Treasury.registerReceiver`
             to enable GOVTOKEN emissions on the newly deployed `ConvexDepositToken`
     */
    function deployNewInstance(uint256 pid) external onlyOwner {
        address depositToken = depositTokenImpl.cloneDeterministic(bytes32(pid));

        IConvexDepositToken(depositToken).initialize(pid);

        emit NewDeployment(pid, depositToken);
    }

    function getDepositToken(uint256 pid) external view returns (address) {
        return Clones.predictDeterministicAddress(depositTokenImpl, bytes32(pid));
    }
}
