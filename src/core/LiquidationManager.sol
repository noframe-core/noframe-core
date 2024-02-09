// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/IStabilityPool.sol";
import "../interfaces/IMarketSorting.sol";
import "../interfaces/IBorrowerOperations.sol";
import "../interfaces/IMarketCore.sol";
import "../dependencies/PrismaMath.sol";
import "./SharedBase.sol";

/**
    @title NoFrame Liquidation Manager
    @notice Based on Liquity's `MarketCore`
            https://github.com/liquity/dev/blob/main/packages/contracts/contracts/MarketCore.sol

            This contract has a 1:n relationship with `MarketCore`, handling liquidations
            for every active collateral within the system.

            Anyone can call to liquidate an eligible trove at any time. There is no requirement
            that liquidations happen in order according to trove ICRs. There are three ways that
            a liquidation can occur:

            1. ICR <= 100
               The trove's entire debt and collateral is redistributed between remaining active troves.

            2. 100 < ICR < MCR
               The trove is liquidated using stability pool deposits. The collateral is distributed
               amongst stability pool depositors. If the stability pool's balance is insufficient to
               completely repay the trove, the remaining debt and collateral is redistributed between
               the remaining active troves.

            3. MCR <= ICR < TCR && TCR < CCR
               The trove is liquidated using stability pool deposits. Collateral equal to 110% of
               the value of the debt is distributed between stability pool depositors. The remaining
               collateral is left claimable by the trove owner.
 */
contract LiquidationManager is SharedBase{
    
    mapping(IERC20 => IMarketCore) internal _trovesContracts;

    /*
     * --- Variable container structs for liquidations ---
     *
     * These structs are used to hold, return and assign variables inside the liquidation functions,
     * in order to avoid the error: "CompilerError: Stack too deep".
     **/

    struct LiquidationValues {
        uint256 entireTroveDebt;
        uint256 entireTroveColl;
        uint256 collGasCompensation;
        uint256 debtGasCompensation;
        uint256 debtToOffset;
        uint256 collToSendToSP;
        uint256 debtToRedistribute;
        uint256 collToRedistribute;
        uint256 collSurplus;
    }

    struct LiquidationTotals {
        uint256 totalCollInSequence;
        uint256 totalDebtInSequence;
        uint256 totalCollGasCompensation;
        uint256 totalDebtGasCompensation;
        uint256 totalDebtToOffset;
        uint256 totalCollToSendToSP;
        uint256 totalDebtToRedistribute;
        uint256 totalCollToRedistribute;
        uint256 totalCollSurplus;
    }

    event TroveUpdated(
        address indexed _borrower,
        uint256 _debt,
        uint256 _coll,
        uint256 _stake,
        TroveManagerOperation _operation
    );
    event TroveLiquidated(address indexed _borrower, uint256 _debt, uint256 _coll, TroveManagerOperation _operation);
    event Liquidation(
        uint256 _liquidatedDebt,
        uint256 _liquidatedColl,
        uint256 _collGasCompensation,
        uint256 _debtGasCompensation
    );
    event TroveUpdated(address indexed _borrower, uint256 _debt, uint256 _coll, uint256 stake, uint8 operation);
    event TroveLiquidated(address indexed _borrower, uint256 _debt, uint256 _coll, uint8 operation);

    enum TroveManagerOperation {
        applyPendingRewards,
        liquidateInNormalMode,
        liquidateInRecoveryMode,
        redeemCollateral
    }

    constructor(
        address _addressProvider
    ) SharedBase(_addressProvider) {
        //
    }

    function enableCollateral(address _troveManager, IERC20 _collateral) external {
        require(msg.sender == address(factory()), "Not factory");
        _trovesContracts[_collateral] = IMarketCore(_troveManager);
    }

    // --- Trove Liquidation functions ---

    /**
        @notice Liquidate a single trove
        @dev Reverts if the trove is not active, or cannot be liquidated
        @param collateral Collateral type to perform liquidation against
        @param borrower Borrower address to liquidate
     */
    function liquidate(IERC20 collateral, address borrower) external {
        IMarketCore troveManager = _trovesContracts[collateral];

        require(troveManager.getTroveStatus(borrower) == 1, "MarketCore: Trove does not exist or is closed");

        address[] memory borrowers = new address[](1);
        borrowers[0] = borrower;
        batchLiquidateTroves(collateral, borrowers);
    }

    /**
        @notice Liquidate a sequence of troves
        @dev Iterates through troves starting with the lowest ICR
        @param collateral Collateral type to perform liquidations against
        @param maxTrovesToLiquidate The maximum number of troves to liquidate
        @param maxICR Maximum ICR to liquidate. Should be set to MCR if the system
                      is not in recovery mode, to minimize gas costs for this call.
     */
    function liquidateTroves(IERC20 collateral, uint256 maxTrovesToLiquidate, uint256 maxICR) external {
        IMarketCore troveManager = _trovesContracts[collateral];
        troveManager.updateBalances();

        IStabilityPool stabilityPoolCached = stabilityPool();
        IMarketSorting sortedTrovesCached = IMarketSorting(troveManager.sortedTroves());

        LiquidationValues memory singleLiquidation;
        LiquidationTotals memory totals;

        uint trovesRemaining = maxTrovesToLiquidate;
        uint troveCount = troveManager.getTroveOwnersCount();
        uint price = troveManager.fetchPrice();
        uint debtInStabPool = stabilityPoolCached.getTotalDebtTokenDeposits();
        bool sunsetting = troveManager.sunsetting();

        while (trovesRemaining > 0 && troveCount > 1) {
            address account = sortedTrovesCached.getLast();
            uint ICR = troveManager.getCurrentICR(account, price);
            if (ICR > maxICR) {
                // set to 0 to ensure the next if block evaluates false
                trovesRemaining = 0;
                break;
            }
            if (ICR <= _100pct) {
                singleLiquidation = _liquidateWithoutSP(troveManager, account);
                _applyLiquidationValuesToTotals(totals, singleLiquidation);
            } else if (ICR < troveManager.MCR()) {
                singleLiquidation = _liquidateNormalMode(troveManager, account, debtInStabPool, sunsetting);
                debtInStabPool -= singleLiquidation.debtToOffset;
                _applyLiquidationValuesToTotals(totals, singleLiquidation);
            } else break; // break if the loop reaches a Trove with ICR >= MCR
            unchecked {
                --trovesRemaining;
                --troveCount;
            }
        }
        if (trovesRemaining > 0 && !sunsetting && troveCount > 1) {
            (uint entireSystemColl, uint entireSystemDebt) = borrowerOperations().getGlobalSystemBalances();
            entireSystemColl -= totals.totalCollToSendToSP * price;
            entireSystemDebt -= totals.totalDebtToOffset;
            address nextAccount = sortedTrovesCached.getLast();
            while (trovesRemaining > 0 && troveCount > 1) {
                uint ICR = troveManager.getCurrentICR(nextAccount, price);
                if (ICR > maxICR) break;
                unchecked {
                    --trovesRemaining;
                }
                address account = nextAccount;
                nextAccount = sortedTrovesCached.getPrev(account);

                singleLiquidation = _tryLiquidateWithCap(
                    troveManager,
                    account,
                    ICR,
                    debtInStabPool,
                    PrismaMath._computeCR(entireSystemColl, entireSystemDebt),
                    price
                );
                if (singleLiquidation.debtToOffset == 0) continue;
                debtInStabPool -= singleLiquidation.debtToOffset;
                entireSystemColl -= (singleLiquidation.collToSendToSP + singleLiquidation.collSurplus) * price;
                entireSystemDebt -= singleLiquidation.debtToOffset;
                _applyLiquidationValuesToTotals(totals, singleLiquidation);
                unchecked {
                    --troveCount;
                }
            }
        }

        require(totals.totalDebtInSequence > 0, "MarketCore: nothing to liquidate");
        if (totals.totalDebtToOffset > 0 || totals.totalCollToSendToSP > 0) {
            // Move liquidated collateral and Debt to the appropriate pools
            stabilityPoolCached.offset(address(collateral), totals.totalDebtToOffset, totals.totalCollToSendToSP);
            troveManager.decreaseDebtAndSendCollateral(
                address(stabilityPoolCached),
                totals.totalDebtToOffset,
                totals.totalCollToSendToSP
            );
        }
        troveManager.finalizeLiquidation(
            msg.sender,
            totals.totalDebtToRedistribute,
            totals.totalCollToRedistribute,
            totals.totalCollSurplus,
            totals.totalDebtGasCompensation,
            totals.totalCollGasCompensation
        );

        emit Liquidation(
            totals.totalDebtInSequence,
            totals.totalCollInSequence - totals.totalCollGasCompensation - totals.totalCollSurplus,
            totals.totalCollGasCompensation,
            totals.totalDebtGasCompensation
        );
    }

    /**
        @notice Liquidate a custom list of troves
        @dev Reverts if there is not a single trove that can be liquidated
        @param collateral Collateral type to perform liquidations against
        @param _troveArray List of borrower addresses to liquidate. Troves that were already
                           liquidated, or cannot be liquidated, are ignored.
     */
    /*
     * Attempt to liquidate a custom list of troves provided by the caller.
     */
    function batchLiquidateTroves(IERC20 collateral, address[] memory _troveArray) public {
        IMarketCore troveManager = _trovesContracts[collateral];
        require(_troveArray.length != 0, "MarketCore: Calldata address array must not be empty");
        troveManager.updateBalances();

        LiquidationValues memory singleLiquidation;
        LiquidationTotals memory totals;

        IStabilityPool stabilityPoolCached = stabilityPool();
        uint debtInStabPool = stabilityPoolCached.getTotalDebtTokenDeposits();
        uint price = troveManager.fetchPrice();
        bool sunsetting = troveManager.sunsetting();
        uint troveCount = troveManager.getTroveOwnersCount();
        uint length = _troveArray.length;
        uint troveIter;

        while (troveIter < length && troveCount > 1) {
            // first iteration round, when all liquidated troves have ICR < MCR we do not need to track TCR
            address account = _troveArray[troveIter];

            // closed / non-existent troves return an ICR of type(uint).max and are ignored
            uint ICR = troveManager.getCurrentICR(account, price);
            if (ICR <= _100pct) {
                singleLiquidation = _liquidateWithoutSP(troveManager, account);
            } else if (ICR < troveManager.MCR()) {
                singleLiquidation = _liquidateNormalMode(troveManager, account, debtInStabPool, sunsetting);
                debtInStabPool -= singleLiquidation.debtToOffset;
            } else {
                // As soon as we find a trove with ICR >= MCR we need to start tracking the global TCR with the next loop
                break;
            }
            _applyLiquidationValuesToTotals(totals, singleLiquidation);
            unchecked {
                ++troveIter;
                --troveCount;
            }
        }

        if (troveIter < length && troveCount > 1) {
            // second iteration round, if we receive a trove with ICR > MCR and need to track TCR
            (uint256 entireSystemColl, uint256 entireSystemDebt) = borrowerOperations().getGlobalSystemBalances();
            entireSystemColl -= totals.totalCollToSendToSP * price;
            entireSystemDebt -= totals.totalDebtToOffset;
            while (troveIter < length && troveCount > 1) {
                address account = _troveArray[troveIter];
                uint ICR = troveManager.getCurrentICR(account, price);
                unchecked {
                    ++troveIter;
                }
                if (ICR <= _100pct) {
                    singleLiquidation = _liquidateWithoutSP(troveManager, account);
                } else if (ICR < troveManager.MCR()) {
                    singleLiquidation = _liquidateNormalMode(troveManager, account, debtInStabPool, sunsetting);
                } else {
                    if (sunsetting) continue;
                    uint256 TCR = PrismaMath._computeCR(entireSystemColl, entireSystemDebt);
                    singleLiquidation = _tryLiquidateWithCap(troveManager, account, ICR, debtInStabPool, TCR, price);
                    if (singleLiquidation.debtToOffset == 0) continue;
                }

                debtInStabPool -= singleLiquidation.debtToOffset;
                entireSystemColl -= (singleLiquidation.collToSendToSP + singleLiquidation.collSurplus) * price;
                entireSystemDebt -= singleLiquidation.debtToOffset;
                _applyLiquidationValuesToTotals(totals, singleLiquidation);
                unchecked {
                    --troveCount;
                }
            }
        }

        require(totals.totalDebtInSequence > 0, "MarketCore: nothing to liquidate");

        if (totals.totalDebtToOffset > 0 || totals.totalCollToSendToSP > 0) {
            // Move liquidated collateral and Debt to the appropriate pools
            stabilityPoolCached.offset(address(collateral), totals.totalDebtToOffset, totals.totalCollToSendToSP);
            troveManager.decreaseDebtAndSendCollateral(
                address(stabilityPoolCached),
                totals.totalDebtToOffset,
                totals.totalCollToSendToSP
            );
        }
        troveManager.finalizeLiquidation(
            msg.sender,
            totals.totalDebtToRedistribute,
            totals.totalCollToRedistribute,
            totals.totalCollSurplus,
            totals.totalDebtGasCompensation,
            totals.totalCollGasCompensation
        );

        emit Liquidation(
            totals.totalDebtInSequence,
            totals.totalCollInSequence - totals.totalCollGasCompensation - totals.totalCollSurplus,
            totals.totalCollGasCompensation,
            totals.totalDebtGasCompensation
        );
    }

    /**
        @dev Perform a "normal" liquidation, where 100% < ICR < 110%. The trove
             is liquidated as much as possible using the stability pool. Any
             remaining debt and collateral are redistributed between active troves.
     */
    function _liquidateNormalMode(
        IMarketCore troveManager,
        address _borrower,
        uint256 _debtInStabPool,
        bool sunsetting
    ) internal returns (LiquidationValues memory singleLiquidation) {
        uint pendingDebtReward;
        uint pendingCollReward;

        (
            singleLiquidation.entireTroveDebt,
            singleLiquidation.entireTroveColl,
            pendingDebtReward,
            pendingCollReward
        ) = troveManager.getEntireDebtAndColl(_borrower);

        troveManager.movePendingTroveRewardsToActiveBalances(pendingDebtReward, pendingCollReward);

        singleLiquidation.collGasCompensation = _getCollGasCompensation(singleLiquidation.entireTroveColl);
        singleLiquidation.debtGasCompensation = DEBT_GAS_COMPENSATION;
        uint256 collToLiquidate = singleLiquidation.entireTroveColl - singleLiquidation.collGasCompensation;

        (
            singleLiquidation.debtToOffset,
            singleLiquidation.collToSendToSP,
            singleLiquidation.debtToRedistribute,
            singleLiquidation.collToRedistribute
        ) = _getOffsetAndRedistributionVals(
            singleLiquidation.entireTroveDebt,
            collToLiquidate,
            _debtInStabPool,
            sunsetting
        );

        troveManager.closeTroveByLiquidation(_borrower);
        emit TroveLiquidated(
            _borrower,
            singleLiquidation.entireTroveDebt,
            singleLiquidation.entireTroveColl,
            TroveManagerOperation.liquidateInNormalMode
        );
        emit TroveUpdated(_borrower, 0, 0, 0, TroveManagerOperation.liquidateInNormalMode);
        return singleLiquidation;
    }

    /**
        @dev Attempt to liquidate a single trove in recovery mode.
             If 110% <= ICR < current TCR (accounting for the preceding liquidations in the current sequence)
             and there is Debt in the Stability Pool, only offset, with no redistribution,
             but at a capped rate of 1.1 and only if the whole debt can be liquidated.
             The remainder due to the capped rate will be claimable as collateral surplus.
     */
    function _tryLiquidateWithCap(
        IMarketCore troveManager,
        address _borrower,
        uint _ICR,
        uint256 _debtInStabPool,
        uint _TCR,
        uint256 _price
    ) internal returns (LiquidationValues memory singleLiquidation) {
        if ((_ICR >= _TCR) || (_TCR >= MTCR())) {
            // do not liquidate
            return singleLiquidation;
        }

        uint entireTroveDebt;
        uint entireTroveColl;
        uint pendingDebtReward;
        uint pendingCollReward;

        (entireTroveDebt, entireTroveColl, pendingDebtReward, pendingCollReward) = troveManager.getEntireDebtAndColl(
            _borrower
        );

        if (entireTroveDebt > _debtInStabPool) {
            // do not liquidate if the entire trove cannot be liquidated via SP
            return singleLiquidation;
        }

        troveManager.movePendingTroveRewardsToActiveBalances(pendingDebtReward, pendingCollReward);

        singleLiquidation.entireTroveDebt = entireTroveDebt;
        singleLiquidation.entireTroveColl = entireTroveColl;
        uint256 collToOffset = (entireTroveDebt * troveManager.MCR()) / _price;

        singleLiquidation.collGasCompensation = _getCollGasCompensation(collToOffset);
        singleLiquidation.debtGasCompensation = DEBT_GAS_COMPENSATION;

        singleLiquidation.debtToOffset = entireTroveDebt;
        singleLiquidation.collToSendToSP = collToOffset - singleLiquidation.collGasCompensation;

        troveManager.closeTroveByLiquidation(_borrower);

        uint256 collSurplus = entireTroveColl - collToOffset;
        if (collSurplus > 0) {
            singleLiquidation.collSurplus = collSurplus;
            troveManager.addCollateralSurplus(_borrower, collSurplus);
        }

        emit TroveLiquidated(
            _borrower,
            entireTroveDebt,
            singleLiquidation.collToSendToSP,
            TroveManagerOperation.liquidateInRecoveryMode
        );
        emit TroveUpdated(_borrower, 0, 0, 0, TroveManagerOperation.liquidateInRecoveryMode);

        return singleLiquidation;
    }

    /**
        @dev Liquidate a trove without using the stability pool. All debt and collateral
             are distributed porportionally between the remaining active troves.
     */
    function _liquidateWithoutSP(
        IMarketCore troveManager,
        address _borrower
    ) internal returns (LiquidationValues memory singleLiquidation) {
        uint pendingDebtReward;
        uint pendingCollReward;

        (
            singleLiquidation.entireTroveDebt,
            singleLiquidation.entireTroveColl,
            pendingDebtReward,
            pendingCollReward
        ) = troveManager.getEntireDebtAndColl(_borrower);

        singleLiquidation.collGasCompensation = _getCollGasCompensation(singleLiquidation.entireTroveColl);
        singleLiquidation.debtGasCompensation = DEBT_GAS_COMPENSATION;
        troveManager.movePendingTroveRewardsToActiveBalances(pendingDebtReward, pendingCollReward);

        singleLiquidation.debtToOffset = 0;
        singleLiquidation.collToSendToSP = 0;
        singleLiquidation.debtToRedistribute = singleLiquidation.entireTroveDebt;
        singleLiquidation.collToRedistribute =
            singleLiquidation.entireTroveColl -
            singleLiquidation.collGasCompensation;

        troveManager.closeTroveByLiquidation(_borrower);
        emit TroveLiquidated(
            _borrower,
            singleLiquidation.entireTroveDebt,
            singleLiquidation.entireTroveColl,
            TroveManagerOperation.liquidateInRecoveryMode
        );
        emit TroveUpdated(_borrower, 0, 0, 0, TroveManagerOperation.liquidateInRecoveryMode);
        return singleLiquidation;
    }

    /* In a full liquidation, returns the values for a trove's coll and debt to be offset, and coll and debt to be
     * redistributed to active troves.
     */
    function _getOffsetAndRedistributionVals(
        uint256 _debt,
        uint256 _coll,
        uint256 _debtInStabPool,
        bool sunsetting
    )
        internal
        pure
        returns (uint256 debtToOffset, uint256 collToSendToSP, uint256 debtToRedistribute, uint256 collToRedistribute)
    {
        if (_debtInStabPool > 0 && !sunsetting) {
            /*
             * Offset as much debt & collateral as possible against the Stability Pool, and redistribute the remainder
             * between all active troves.
             *
             *  If the trove's debt is larger than the deposited Debt in the Stability Pool:
             *
             *  - Offset an amount of the trove's debt equal to the Debt in the Stability Pool
             *  - Send a fraction of the trove's collateral to the Stability Pool, equal to the fraction of its offset debt
             *
             */
            debtToOffset = PrismaMath._min(_debt, _debtInStabPool);
            collToSendToSP = (_coll * debtToOffset) / _debt;
            debtToRedistribute = _debt - debtToOffset;
            collToRedistribute = _coll - collToSendToSP;
        } else {
            debtToOffset = 0;
            collToSendToSP = 0;
            debtToRedistribute = _debt;
            collToRedistribute = _coll;
        }
    }

    /**
        @dev Adds values from `singleLiquidation` to `totals`
             Calling this function mutates `totals`, the change is done in-place
             to avoid needless expansion of memory
     */
    function _applyLiquidationValuesToTotals(
        LiquidationTotals memory totals,
        LiquidationValues memory singleLiquidation
    ) internal pure {
        // Tally all the values with their respective running totals
        totals.totalCollGasCompensation = totals.totalCollGasCompensation + singleLiquidation.collGasCompensation;
        totals.totalDebtGasCompensation = totals.totalDebtGasCompensation + singleLiquidation.debtGasCompensation;
        totals.totalDebtInSequence = totals.totalDebtInSequence + singleLiquidation.entireTroveDebt;
        totals.totalCollInSequence = totals.totalCollInSequence + singleLiquidation.entireTroveColl;
        totals.totalDebtToOffset = totals.totalDebtToOffset + singleLiquidation.debtToOffset;
        totals.totalCollToSendToSP = totals.totalCollToSendToSP + singleLiquidation.collToSendToSP;
        totals.totalDebtToRedistribute = totals.totalDebtToRedistribute + singleLiquidation.debtToRedistribute;
        totals.totalCollToRedistribute = totals.totalCollToRedistribute + singleLiquidation.collToRedistribute;
        totals.totalCollSurplus = totals.totalCollSurplus + singleLiquidation.collSurplus;
    }
}
