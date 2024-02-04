// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "./AddressProvider.sol";

import "../interfaces/ITroveManager.sol";
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
contract BaseNoFrame {
    AddressProvider public immutable addressProvider;

    constructor(address _addressProvider) {
        addressProvider = AddressProvider(_addressProvider);
    }

    modifier onlyOwner() {
        require(msg.sender == addressProvider.owner(), "Only owner");
        _;
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



}
