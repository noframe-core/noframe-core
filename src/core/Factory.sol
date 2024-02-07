// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "../interfaces/IMarket.sol";
import "../interfaces/IBorrowerOperations.sol";
import "../interfaces/IStablecoin.sol";
import "../interfaces/ISortedTroves.sol";
import "../interfaces/IStabilityPool.sol";
import "../interfaces/ILiquidationManager.sol";
import "./SharedBase.sol";

/**
    @title NoFrame Trove Factory
    @notice Deploys cloned pairs of `Market` and `SortedTroves` in order to
            add new collateral types within the system.
 */
contract Factory is SharedBase {
    using Clones for address;

    mapping(address collateral => address troveManagerImpl) public troveManagerOverrides;
    mapping(address collateral => bool deployed) public collateralDeployed;

    struct DeploymentParams {
        uint256 minuteDecayFactor;
        uint256 redemptionFeeFloor;
        uint256 maxRedemptionFee;
        uint256 borrowingFeeFloor;
        uint256 maxBorrowingFee;
        uint256 interestRate;
        uint256 maxDebt;
    }

    error CollateralAlreadyDeployed(address collateral);

    event NewDeployment(address collateral, address troveManager, address sortedTroves);

    constructor(address _addressProvider) SharedBase(_addressProvider) {
        //
    }


    /**
        @notice Deploy new instances of `Market` and `SortedTroves`, adding
                a new collateral type to the system.
        @dev After calling this function, the owner should also call `Treasury.registerReceiver`
             to enable GOVTOKEN emissions on the newly deployed `Market`
        @param collateral Collateral token to use in new deployment
        // TODO
     */
    function deployNewInstance(
        address collateral,
        uint256 _mcr,
        uint256 _ccr,
        uint256 minuteDecayFactor,
        uint256 redemptionFeeFloor,
        uint256 borrowingFeeFloor,
        uint256 maxBorrowingFee,
        uint256 interestRate,
        uint256 maxDebt
    ) external onlyOwner {
        if (collateralDeployed[collateral]) revert CollateralAlreadyDeployed(collateral);

        address troveManager;
        troveManager = troveManagerImpl().cloneDeterministic(bytes32(bytes20(collateral)));

        address sortedTroves;
        sortedTroves = sortedTrovesImpl().cloneDeterministic(bytes32(bytes20(collateral)));

        ISortedTroves(sortedTroves).initMarket(troveManager);
        IMarket(troveManager).initMarket(
            _mcr, 
            _ccr, 
            sortedTroves, 
            collateral,
            minuteDecayFactor,
            redemptionFeeFloor,
            borrowingFeeFloor,
            maxBorrowingFee,
            interestRate,
            maxDebt,
            address(addressProvider)
            );

        stabilityPool().enableCollateral(collateral);
        liquidationManager().enableCollateral(troveManager, collateral);
        stablecoin().enableCollateral(troveManager);
        borrowerOperations().enableCollateral(troveManager, collateral);
        collateralDeployed[collateral] = true;
        emit NewDeployment(collateral, troveManager, sortedTroves);
    }

    function getTroveManager(address collateral) public view returns (IMarket) {
        if (!collateralDeployed[collateral]) return IMarket(address(0));
        return IMarket(Clones.predictDeterministicAddress(troveManagerImpl(), bytes32(bytes20(collateral))));
    }
}
