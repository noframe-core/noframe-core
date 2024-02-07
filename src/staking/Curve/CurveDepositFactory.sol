// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "../../core/SharedBase.sol";
import "../../interfaces/ICurveProxy.sol";

interface ICurveDepositToken {
    function initialize(address _gauge) external;
}

/**
    @notice NoFrame Curve Factory
    @title Deploys clones of `CurveDepositToken` as directed by the NoFrame DAO
 */
contract CurveFactory is SharedBase {
    using Clones for address;

    ICurveProxy public immutable curveProxy;
    address public immutable depositTokenImpl;

    event NewDeployment(address gauge, address depositToken);

    constructor(address _addressProvider, ICurveProxy _curveProxy, address _depositTokenImpl) SharedBase(_addressProvider) {
        curveProxy = _curveProxy;
        depositTokenImpl = _depositTokenImpl;
    }

    /**
        @dev After calling this function, the owner should also call `Treasury.registerReceiver`
             to enable GOVTOKEN emissions on the newly deployed `CurveDepositToken`
     */
    function deployNewInstance(address gauge) external onlyOwner {
        address depositToken = depositTokenImpl.cloneDeterministic(bytes32(bytes20(gauge)));

        ICurveDepositToken(depositToken).initialize(gauge);
        curveProxy.setPerGaugeApproval(depositToken, gauge);
        // TODO enable GOVTOKEN emissions

        emit NewDeployment(gauge, depositToken);
    }

    function getDepositToken(address gauge) external view returns (address) {
        return Clones.predictDeterministicAddress(depositTokenImpl, bytes32(bytes20(gauge)));
    }
}
