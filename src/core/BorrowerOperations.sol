// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/IMarketCore.sol";
import "../dependencies/PrismaMath.sol";
import "../dependencies/DelegatedOps.sol";
import "./SharedBase.sol";


import {Test, console} from "forge-std/Test.sol";

/**
    @title NoFrame Borrower Operations
    @notice Based on Liquity's `BorrowerOperations`
            https://github.com/liquity/dev/blob/main/packages/contracts/contracts/BorrowerOperations.sol

            NoFrame's implementation is modified to support multiple collaterals. There is a 1:n
            relationship between `BorrowerOperations` and each `MarketCore` / `MarketSorting` pair.
 */
contract BorrowerOperations is SharedBase, DelegatedOps {
    uint256 public minNetDebt;

    mapping(IERC20 => TrovesContracts) internal _trovesContracts;
    IMarketCore[] internal _troveManagers;

    struct TrovesContracts {
        IMarketCore troveManager;
        uint16 index;
    }

    struct SystemBalances {
        uint256[] collaterals;
        uint256[] debts;
        uint256[] prices;
    }

    struct LocalVariables_adjustTrove {
        uint256 price;
        uint256 collChange;
        uint256 netDebtChange;
        bool isCollIncrease;
        uint256 debt;
        uint256 coll;
        uint256 newDebt;
        uint256 newColl;
        uint256 stake;
        bool isDebtIncrease;
        uint256 debtChange;
    }

    struct LocalVariables_openTrove {
        uint256 price;
        uint256 netDebt;
        uint256 compositeDebt;
        uint256 ICR;
        uint256 NICR;
        uint256 stake;
        uint256 arrayIndex;
    }

    enum BorrowerOperation {
        openTrove,
        closeTrove,
        adjustTrove
    }

    event TroveUpdated(
        address indexed _borrower,
        uint256 _debt,
        uint256 _coll,
        uint256 stake,
        BorrowerOperation operation
    );
    event TroveCreated(address indexed _borrower, uint256 arrayIndex);
    event TroveUpdated(address indexed _borrower, uint256 _debt, uint256 _coll, uint256 stake, uint8 operation);
    event BorrowingFeePaid(address indexed borrower, uint256 amount);
    event CollateralEnabled(address collateralToken);

    constructor(
        address _addressProvider,
        uint256 _minNetDebt
    ) SharedBase(_addressProvider) {
        _setMinNetDebt(_minNetDebt);
    }

    function setMinNetDebt(uint256 _minNetDebt) public onlyOwner {
        _setMinNetDebt(_minNetDebt);
    }

    function _setMinNetDebt(uint256 _minNetDebt) internal {
        require(_minNetDebt > 0);
        minNetDebt = _minNetDebt;
    }

    function enableCollateral(IMarketCore troveManager, IERC20 collateralToken) external {
        require(msg.sender == factory(), "!factory");
        require(address(_trovesContracts[collateralToken].troveManager) == address(0), "Collateral already enabled");
        _trovesContracts[collateralToken] = TrovesContracts(troveManager, uint16(_troveManagers.length));
        _troveManagers.push(troveManager);
        emit CollateralEnabled(address(collateralToken));
    }

    function getTCR(
        SystemBalances memory balances
    ) public view returns (uint256 amount, uint256 totalPricedCollateral, uint256 totalDebt) {
        uint256 loopEnd = balances.collaterals.length;
        for (uint256 i; i < loopEnd; ) {
            totalPricedCollateral += (balances.collaterals[i] * balances.prices[i]);
            totalDebt += balances.debts[i];
            unchecked {
                ++i;
            }
        }
        amount = PrismaMath._computeCR(totalPricedCollateral, totalDebt);

        return (amount, totalPricedCollateral, totalDebt);
    }

    /**
        @notice Get total collateral and debt balances for all active collaterals, as well as
                the current collateral prices
        @dev Not a view because fetching from the oracle is state changing.
             Can still be accessed as a view from within the UX.
     */
    function fetchBalances() public returns (SystemBalances memory balances) {
        uint256 loopEnd = _troveManagers.length;
        balances = SystemBalances({
            collaterals: new uint256[](loopEnd),
            debts: new uint256[](loopEnd),
            prices: new uint256[](loopEnd)
        });
        for (uint256 i; i < loopEnd; ) {
            IMarketCore troveManager = _troveManagers[i];
            (uint256 collateral, uint256 debt, uint256 price) = troveManager.getEntireSystemBalances();
            balances.collaterals[i] = collateral;
            balances.debts[i] = debt;
            balances.prices[i] = price;
            unchecked {
                ++i;
            }
        }
    }

    function checkRecoveryMode(uint256 TCR) public returns (bool) {
        return TCR < MTCR();
    }

    function getCompositeDebt(uint256 _debt) external view returns (uint256) {
        return _getCompositeDebt(_debt);
    }

    // --- Borrower Trove Operations ---

    function openTrove(
        IERC20 collateralToken,
        address account,
        uint256 _maxFeePercentage,
        uint256 _collateralAmount,
        uint256 _debtAmount,
        address _upperHint,
        address _lowerHint
    ) external callerOrDelegated(account) {
        require(!addressProvider.paused(), "Deposits are paused");

        (IMarketCore troveManager, uint256 index) = _getTroveManagerAndIndex(collateralToken);

        LocalVariables_openTrove memory vars;
        bool isRecoveryMode;
        uint256 totalPricedCollateral;
        uint256 totalDebt;
        (vars.price, totalPricedCollateral, totalDebt, isRecoveryMode) = _getTCRData(index);

        _requireValidMaxFeePercentage(_maxFeePercentage);

        vars.netDebt = _debtAmount;

        if (!isRecoveryMode) {
            vars.netDebt = vars.netDebt + _triggerBorrowingFee(troveManager, account, _maxFeePercentage, _debtAmount);
        }
        _requireAtLeastMinNetDebt(vars.netDebt);

        // ICR is based on the composite debt, i.e. the requested Debt amount + Debt borrowing fee + Debt gas comp.
        vars.compositeDebt = _getCompositeDebt(vars.netDebt);
        vars.ICR = PrismaMath._computeCR(_collateralAmount, vars.compositeDebt, vars.price);
        vars.NICR = PrismaMath._computeNominalCR(_collateralAmount, vars.compositeDebt);

        if (isRecoveryMode) {
            _requireICRisAboveCCR(vars.ICR, troveManager.CCR());
        } else {
            _requireICRisAboveMCR(vars.ICR, troveManager.MCR());
            uint256 newTCR = _getNewTCRFromTroveChange(
                totalPricedCollateral,
                totalDebt,
                _collateralAmount * vars.price,
                true,
                vars.compositeDebt,
                true
            ); // bools: coll increase, debt increase
            _requireNewTCRisAboveCCR(newTCR);
        }

        // Create the trove
        (vars.stake, vars.arrayIndex) = troveManager.openTrove(
            account,
            _collateralAmount,
            vars.compositeDebt,
            vars.NICR,
            _upperHint,
            _lowerHint
        );
        emit TroveCreated(account, vars.arrayIndex);

        // Move the collateral to the Trove Manager
        collateralToken.transferFrom(msg.sender, address(troveManager), _collateralAmount);

        //  and mint the DebtAmount to the caller and gas compensation for Gas Pool
        stablecoin().mintWithGasCompensation(msg.sender, _debtAmount);

        emit TroveUpdated(account, vars.compositeDebt, _collateralAmount, vars.stake, BorrowerOperation.openTrove);
    }

    // Send collateral to a trove
    function addColl(
        IERC20 collateralToken,
        address account,
        uint256 _collateralAmount,
        address _upperHint,
        address _lowerHint
    ) external callerOrDelegated(account) {
        require(!addressProvider.paused(), "Trove adjustments are paused");
        _adjustTrove(collateralToken, account, 0, _collateralAmount, 0, 0, false, _upperHint, _lowerHint);
    }

    // Withdraw collateral from a trove
    function withdrawColl(
        IERC20 collateralToken,
        address account,
        uint256 _collWithdrawal,
        address _upperHint,
        address _lowerHint
    ) external callerOrDelegated(account) {
        _adjustTrove(collateralToken, account, 0, 0, _collWithdrawal, 0, false, _upperHint, _lowerHint);
    }

    // Withdraw Debt tokens from a trove: mint new Debt tokens to the owner, and increase the trove's debt accordingly
    function withdrawDebt(
        IERC20 collateralToken,
        address account,
        uint256 _maxFeePercentage,
        uint256 _debtAmount,
        address _upperHint,
        address _lowerHint
    ) external callerOrDelegated(account) {
        require(!addressProvider.paused(), "Withdrawals are paused");
        _adjustTrove(collateralToken, account, _maxFeePercentage, 0, 0, _debtAmount, true, _upperHint, _lowerHint);
    }

    // Repay Debt tokens to a Trove: Burn the repaid Debt tokens, and reduce the trove's debt accordingly
    function repayDebt(
        IERC20 collateralToken,
        address account,
        uint256 _debtAmount,
        address _upperHint,
        address _lowerHint
    ) external callerOrDelegated(account) {
        _adjustTrove(collateralToken, account, 0, 0, 0, _debtAmount, false, _upperHint, _lowerHint);
    }

    function adjustTrove(
        IERC20 collateralToken,
        address account,
        uint256 _maxFeePercentage,
        uint256 _collDeposit,
        uint256 _collWithdrawal,
        uint256 _debtChange,
        bool _isDebtIncrease,
        address _upperHint,
        address _lowerHint
    ) external callerOrDelegated(account) {
        require((_collDeposit == 0 && !_isDebtIncrease) || !addressProvider.paused(), "Trove adjustments are paused");
        require(_collDeposit == 0 || _collWithdrawal == 0, "BorrowerOperations: Cannot withdraw and add coll");
        _adjustTrove(
            collateralToken,
            account,
            _maxFeePercentage,
            _collDeposit,
            _collWithdrawal,
            _debtChange,
            _isDebtIncrease,
            _upperHint,
            _lowerHint
        );
    }

    function _adjustTrove(
        IERC20 collateralToken,
        address account,
        uint256 _maxFeePercentage,
        uint256 _collDeposit,
        uint256 _collWithdrawal,
        uint256 _debtChange,
        bool _isDebtIncrease,
        address _upperHint,
        address _lowerHint
    ) internal {
        require(
            _collDeposit != 0 || _collWithdrawal != 0 || _debtChange != 0,
            "BorrowerOps: There must be either a collateral change or a debt change"
        );

        (IMarketCore troveManager, uint256 index) = _getTroveManagerAndIndex(collateralToken);
        LocalVariables_adjustTrove memory vars;

        bool isRecoveryMode;
        uint256 totalPricedCollateral;
        uint256 totalDebt;
        (vars.price, totalPricedCollateral, totalDebt, isRecoveryMode) = _getTCRData(index);

        (vars.coll, vars.debt) = troveManager.applyPendingRewards(account);

        // Get the collChange based on whether or not collateral was sent in the transaction
        (vars.collChange, vars.isCollIncrease) = _getCollChange(_collDeposit, _collWithdrawal);
        vars.netDebtChange = _debtChange;
        vars.debtChange = _debtChange;
        vars.isDebtIncrease = _isDebtIncrease;

        if (_isDebtIncrease) {
            require(_debtChange > 0, "BorrowerOps: Debt increase requires non-zero debtChange");
            _requireValidMaxFeePercentage(_maxFeePercentage);
            if (!isRecoveryMode) {
                // If the adjustment incorporates a debt increase and system is in Normal Mode, trigger a borrowing fee
                vars.netDebtChange += _triggerBorrowingFee(troveManager, msg.sender, _maxFeePercentage, _debtChange);
            }
        }

        // Calculate old and new ICRs and check if adjustment satisfies all conditions for the current system mode
        _requireValidAdjustmentInCurrentMode(
            totalPricedCollateral,
            totalDebt,
            isRecoveryMode,
            _collWithdrawal,
            _isDebtIncrease,
            troveManager.CCR(),
            troveManager.MCR(),
            vars
        );

        // When the adjustment is a debt repayment, check it's a valid amount and that the caller has enough Debt
        if (!_isDebtIncrease && _debtChange > 0) {
            _requireAtLeastMinNetDebt(_getNetDebt(vars.debt) - vars.netDebtChange);
        }

        // If we are incrasing collateral, send tokens to the trove manager prior to adjusting the trove
        if (vars.isCollIncrease) collateralToken.transferFrom(msg.sender, address(troveManager), vars.collChange);

        (vars.newColl, vars.newDebt, vars.stake) = troveManager.updateTroveFromAdjustment(
            account,
            vars.collChange,
            vars.isCollIncrease,
            vars.debtChange,
            _isDebtIncrease,
            vars.netDebtChange,
            _upperHint,
            _lowerHint,
            msg.sender
        );

        emit TroveUpdated(account, vars.newDebt, vars.newColl, vars.stake, BorrowerOperation.adjustTrove);
    }

    function closeTrove(IERC20 collateralToken, address account) external callerOrDelegated(account) {
        (IMarketCore troveManager, uint256 index) = _getTroveManagerAndIndex(collateralToken);

        uint256 price;
        bool isRecoveryMode;
        uint256 totalPricedCollateral;
        uint256 totalDebt;
        (price, totalPricedCollateral, totalDebt, isRecoveryMode) = _getTCRData(index);

        require(!isRecoveryMode, "BorrowerOps: Operation not permitted during Recovery Mode");

        (uint256 coll, uint256 debt) = troveManager.applyPendingRewards(account);

        uint256 newTCR = _getNewTCRFromTroveChange(totalPricedCollateral, totalDebt, coll * price, false, debt, false);
        _requireNewTCRisAboveCCR(newTCR);

        troveManager.closeTrove(account, coll, debt);

        emit TroveUpdated(account, 0, 0, 0, BorrowerOperation.closeTrove);

        // Burn the repaid Debt from the user's balance and the gas compensation from the Gas Pool
        stablecoin().burnWithGasCompensation(msg.sender, debt - DEBT_GAS_COMPENSATION);
    }

    // --- Helper functions ---

    function _triggerBorrowingFee(
        IMarketCore _troveManager,
        address _caller,
        uint256 _maxFeePercentage,
        uint256 _debtAmount
    ) internal returns (uint256) {
        uint256 debtFee = _troveManager.decayBaseRateAndGetBorrowingFee(_debtAmount);

        _requireUserAcceptsFee(debtFee, _debtAmount, _maxFeePercentage);

        stablecoin().mint(feeReceiver(), debtFee);

        emit BorrowingFeePaid(_caller, debtFee);

        return debtFee;
    }

    function _getCollChange(
        uint256 _collReceived,
        uint256 _requestedCollWithdrawal
    ) internal pure returns (uint256 collChange, bool isCollIncrease) {
        if (_collReceived != 0) {
            collChange = _collReceived;
            isCollIncrease = true;
        } else {
            collChange = _requestedCollWithdrawal;
        }
    }

    function _requireValidAdjustmentInCurrentMode(
        uint256 totalPricedCollateral,
        uint256 totalDebt,
        bool _isRecoveryMode,
        uint256 _collWithdrawal,
        bool _isDebtIncrease,
        uint256 CCR,
        uint256 MCR,
        LocalVariables_adjustTrove memory _vars
    ) internal view {
        /*
         *In Recovery Mode, only allow:
         *
         * - Pure collateral top-up
         * - Pure debt repayment
         * - Collateral top-up with debt repayment
         * - A debt increase combined with a collateral top-up which makes the ICR >= 150% and improves the ICR (and by extension improves the TCR).
         *
         * In Normal Mode, ensure:
         *
         * - The new ICR is above MCR
         * - The adjustment won't pull the TCR below CCR
         */

        // Get the trove's old ICR before the adjustment
        uint256 oldICR = PrismaMath._computeCR(_vars.coll, _vars.debt, _vars.price);

        // Get the trove's new ICR after the adjustment
        uint256 newICR = _getNewICRFromTroveChange(
            _vars.coll,
            _vars.debt,
            _vars.collChange,
            _vars.isCollIncrease,
            _vars.netDebtChange,
            _isDebtIncrease,
            _vars.price
        );

        if (_isRecoveryMode) {
            require(_collWithdrawal == 0, "BorrowerOps: Collateral withdrawal not permitted Recovery Mode");
            if (_isDebtIncrease) {
                _requireICRisAboveCCR(newICR, CCR);
                _requireNewICRisAboveOldICR(newICR, oldICR);
            }
        } else {
            // if Normal Mode
            _requireICRisAboveMCR(newICR, MCR);
            uint256 newTCR = _getNewTCRFromTroveChange(
                totalPricedCollateral,
                totalDebt,
                _vars.collChange * _vars.price,
                _vars.isCollIncrease,
                _vars.netDebtChange,
                _isDebtIncrease
            );
            _requireNewTCRisAboveCCR(newTCR);
        }
    }

    function _requireICRisAboveMCR(uint256 _newICR, uint256 MCR) internal pure {
        require(_newICR >= MCR, "BorrowerOps: An operation that would result in ICR < MCR is not permitted");
    }

    function _requireICRisAboveCCR(uint256 _newICR, uint256 CCR) internal pure {
        require(_newICR >= CCR, "BorrowerOps: Operation must leave trove with ICR >= CCR");
    }

    function _requireNewICRisAboveOldICR(uint256 _newICR, uint256 _oldICR) internal pure {
        require(_newICR >= _oldICR, "BorrowerOps: Cannot decrease your Trove's ICR in Recovery Mode");
    }

    function _requireNewTCRisAboveCCR(uint256 _newTCR) internal view {
        require(_newTCR >= MTCR(), "BorrowerOps: An operation that would result in TCR < CCR is not permitted");
    }

    function _requireAtLeastMinNetDebt(uint256 _netDebt) internal view {
        require(_netDebt >= minNetDebt, "BorrowerOps: Trove's net debt must be greater than minimum");
    }

    function _requireValidMaxFeePercentage(uint256 _maxFeePercentage) internal pure {
        require(_maxFeePercentage <= DECIMAL_PRECISION, "Max fee percentage must less than or equal to 100%");
    }

    // Compute the new collateral ratio, considering the change in coll and debt. Assumes 0 pending rewards.
    function _getNewICRFromTroveChange(
        uint256 _coll,
        uint256 _debt,
        uint256 _collChange,
        bool _isCollIncrease,
        uint256 _debtChange,
        bool _isDebtIncrease,
        uint256 _price
    ) internal pure returns (uint256) {
        (uint256 newColl, uint256 newDebt) = _getNewTroveAmounts(
            _coll,
            _debt,
            _collChange,
            _isCollIncrease,
            _debtChange,
            _isDebtIncrease
        );

        uint256 newICR = PrismaMath._computeCR(newColl, newDebt, _price);
        return newICR;
    }

    function _getNewTroveAmounts(
        uint256 _coll,
        uint256 _debt,
        uint256 _collChange,
        bool _isCollIncrease,
        uint256 _debtChange,
        bool _isDebtIncrease
    ) internal pure returns (uint256, uint256) {
        uint256 newColl = _coll;
        uint256 newDebt = _debt;

        newColl = _isCollIncrease ? _coll + _collChange : _coll - _collChange;
        newDebt = _isDebtIncrease ? _debt + _debtChange : _debt - _debtChange;

        return (newColl, newDebt);
    }

    function _getNewTCRFromTroveChange(
        uint256 totalColl,
        uint256 totalDebt,
        uint256 _collChange,
        bool _isCollIncrease,
        uint256 _debtChange,
        bool _isDebtIncrease
    ) internal pure returns (uint256) {
        totalDebt = _isDebtIncrease ? totalDebt + _debtChange : totalDebt - _debtChange;
        totalColl = _isCollIncrease ? totalColl + _collChange : totalColl - _collChange;

        uint256 newTCR = PrismaMath._computeCR(totalColl, totalDebt);
        return newTCR;
    }

    function _getTroveManagerAndIndex(
        IERC20 collateralToken
    ) internal view returns (IMarketCore troveManager, uint256 index) {
        TrovesContracts storage t = _trovesContracts[collateralToken];
        (troveManager, index) = (t.troveManager, t.index);

        require(address(troveManager) != address(0), "Collateral not enabled");

        return (troveManager, index);
    }

    function _getTCRData(
        uint256 index
    ) internal returns (uint256 price, uint256 totalPricedCollateral, uint256 totalDebt, bool isRecoveryMode) {
        uint256 amount;
        SystemBalances memory balances = fetchBalances();
        (amount, totalPricedCollateral, totalDebt) = getTCR(balances);
        isRecoveryMode = checkRecoveryMode(amount);

        return (balances.prices[index], totalPricedCollateral, totalDebt, isRecoveryMode);
    }

    function getGlobalSystemBalances() external returns (uint256 totalPricedCollateral, uint256 totalDebt) {
        SystemBalances memory balances = fetchBalances();
        (, totalPricedCollateral, totalDebt) = getTCR(balances);
    }
}
