// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "./Controller.sol";

import "../interfaces/IMarket.sol";
import "../interfaces/IStabilityPool.sol";
import "../interfaces/IBorrowerOperations.sol";
import "../interfaces/IStablecoin.sol";
import "../interfaces/ISortedTroves.sol";
import "../interfaces/ILiquidationManager.sol";
import "../interfaces/IFactory.sol";
import "../interfaces/IPriceFeed.sol";
import "../interfaces/ITreasury.sol";
import "../interfaces/IGovToken.sol";
import "../interfaces/IIncentiveVoting.sol";
import "../interfaces/IEmissionSchedule.sol";
import "../interfaces/IBoostCalculator.sol";



/**
    @title NoFrame Ownable
    @notice Contracts inheriting `PrismaOwnable` have the same owner as `PrismaCore`.
            The ownership cannot be independently modified or renounced.
 */
contract SharedBase {

    uint256 public constant DECIMAL_PRECISION = 1e18;
    uint256 public constant _100pct = 1000000000000000000; // 1e18 == 100%

    // Amount of debt to be locked in gas pool on opening troves
    uint256 public immutable DEBT_GAS_COMPENSATION = 200 * 10**18;

    uint256 public constant PERCENT_DIVISOR = 200; // dividing by 200 yields 0.5%




    Controller public addressProvider;

    constructor(address _addressProvider) {
        addressProvider = Controller(_addressProvider);
    }

    // Returns the composite debt (drawn debt + gas compensation) of a trove, for the purpose of ICR calculation
    function _getCompositeDebt(uint256 _debt) internal view returns (uint256) {
        return _debt + DEBT_GAS_COMPENSATION;
    }

    function _getNetDebt(uint256 _debt) internal view returns (uint256) {
        return _debt - DEBT_GAS_COMPENSATION;
    }


    // Return the amount of collateral to be drawn from a trove's collateral and sent as gas compensation.
    function _getCollGasCompensation(uint256 _entireColl) internal pure returns (uint256) {
        return _entireColl / PERCENT_DIVISOR;
    }

    function _requireUserAcceptsFee(uint256 _fee, uint256 _amount, uint256 _maxFeePercentage) internal pure {
        uint256 feePercentage = (_fee * DECIMAL_PRECISION) / _amount;
        require(feePercentage <= _maxFeePercentage, "Fee exceeded provided maximum");
    }

    modifier onlyOwner() {
        require(msg.sender == addressProvider.owner(), "Only owner");
        _;
    }

    function getWeek() public view returns (uint256 week) {
        return (block.timestamp - addressProvider.startTime()) / 1 weeks;
    }

    function startTime() public view returns (uint256 _startTime) {
        return addressProvider.startTime();
    }

    function owner() public view returns (address) {
        return addressProvider.owner();
    }

    function guardian() public view returns (address) {
        return addressProvider.guardian();
    }
    function feeReceiver() public view returns (address) {
        return addressProvider.feeReceiver();
    }

    function borrowerOperations() public view returns (IBorrowerOperations) {
        return IBorrowerOperations(addressProvider.borrowerOperations());
    }

    function stablecoin() public view returns (IStablecoin) {
        return IStablecoin(addressProvider.stablecoin());
    }

    function factory() public view returns (address) {
        return addressProvider.factory();
    }
    function gasPool() public view returns (address) {
        return addressProvider.gasPool();
    }
    function liquidationManager() public view returns (ILiquidationManager) {
        return ILiquidationManager(addressProvider.liquidationManager());
    }
    function priceFeed() public view returns (address) {
        return addressProvider.priceFeed();
    }
    function stabilityPool() public view returns (IStabilityPool) {
        return IStabilityPool(addressProvider.stabilityPool());
    }
    function sortedTrovesImpl() public view returns (address) {
        return addressProvider.sortedTrovesImpl();
    }
    function troveManagerImpl() public view returns (address) {
        return addressProvider.troveManagerImpl();
    }
    function treasury() public view returns (ITreasury) {
        return ITreasury(addressProvider.treasury());
    }
    function govToken() public view returns (IGovToken) {
        return IGovToken(addressProvider.govToken());
    }
    function incentiveVoting() public view returns (IIncentiveVoting) {
        return IIncentiveVoting(addressProvider.incentiveVoting());
    }
    function tokenLocker() public view returns (ITokenLocker) {
        return ITokenLocker(addressProvider.tokenLocker());
    }
    function emissionSchedule() public view returns (IEmissionSchedule) {
        return IEmissionSchedule(addressProvider.emissionSchedule());
    }
    function boostCalculator() public view returns (IBoostCalculator) {
        return IBoostCalculator(addressProvider.boostCalculator());
    }

    function MTCR() public view returns (uint256) {
        return addressProvider.MTCR();
    }


}
