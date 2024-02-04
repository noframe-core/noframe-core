// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "../interfaces/ITroveManager.sol";
import "../interfaces/IBorrowerOperations.sol";
import "../interfaces/IStablecoin.sol";
import "../interfaces/ISortedTroves.sol";
import "../interfaces/IStabilityPool.sol";
import "../interfaces/ILiquidationManager.sol";
import "./BaseNoFrame.sol";

/**
    @title NoFrame Trove Factory
    @notice Deploys cloned pairs of `TroveManager` and `SortedTroves` in order to
            add new collateral types within the system.
 */
contract Factory is BaseNoFrame {
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

    constructor(address _addressProvider) BaseNoFrame(_addressProvider) {
        //
    }


    /**
        @notice Deploy new instances of `TroveManager` and `SortedTroves`, adding
                a new collateral type to the system.
        @dev After calling this function, the owner should also call `Treasury.registerReceiver`
             to enable GOVTOKEN emissions on the newly deployed `TroveManager`
        @param collateral Collateral token to use in new deployment
        // TODO
     */
    function deployNewInstance(
        address collateral,
        address _mcr,
        address _ccr,
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
        ITroveManager(troveManager).initMarket(
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

    function getTroveManager(address collateral) public view returns (ITroveManager) {
        if (!collateralDeployed[collateral]) return ITroveManager(address(0));
        return ITroveManager(Clones.predictDeterministicAddress(troveManagerImpl(), bytes32(bytes20(collateral))));
    }
}
