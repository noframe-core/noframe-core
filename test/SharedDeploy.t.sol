// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";

import {MockAggregator} from "src/MockAggregator.sol";
import {MockTellor} from "src/MockTellor.sol";
import {AddressProvider} from "src/core/AddressProvider.sol";
import {GasPool} from "src/core/GasPool.sol";
import {PriceFeed} from "src/core/PriceFeed.sol";
import {SortedTroves} from "src/core/SortedTroves.sol";
import {TroveManager} from "src/core/TroveManager.sol";
import {Factory} from "src/core/Factory.sol";
import {StabilityPool} from "src/core/StabilityPool.sol";
import {Stablecoin} from "src/core/Stablecoin.sol";
import {BorrowerOperations} from "src/core/BorrowerOperations.sol";
import {LiquidationManager} from "src/core/LiquidationManager.sol";
import {FeeReceiver} from "src/dao/FeeReceiver.sol";
import {TokenLocker} from "src/dao/TokenLocker.sol";
import {IncentiveVoting} from "src/dao/IncentiveVoting.sol";
import {GovToken} from "src/dao/GovToken.sol";
import {EmissionSchedule} from "src/dao/EmissionSchedule.sol";
import {Treasury} from "src/dao/Treasury.sol";
import {BoostCalculator} from "src/dao/BoostCalculator.sol";
import {AdminVoting} from "src/dao/AdminVoting.sol";

abstract contract SharedDeploy is Test {

    address deployer = address(bytes20(bytes("deployer")));

    MockAggregator mock_chainlink;
    MockTellor mock_tellor;
    AddressProvider addressProvider;
    FeeReceiver fee_receiver;
    GasPool gas_pool;
    PriceFeed pricefeed;
    SortedTroves st_impl;
    TroveManager tm_impl;
    Factory factory;
    LiquidationManager liquidationManager;
    StabilityPool stabilityPool;
    BorrowerOperations borrowerOperations;
    TokenLocker tokenLocker;
    IncentiveVoting incentiveVoting;
    GovToken govToken;
    EmissionSchedule emissionSchedule;
    Treasury treasury;
    BoostCalculator boostCalculator;
    Stablecoin stablecoin;
    AdminVoting adminVoting;

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_ARBITRUM"));
        deploy();
    }

    function deploy() public {

        uint256 GAS_COMP = 200 * 10**18;
        uint256 MIN_DEBT = 1800 * 10**18;
        uint256 lockToTokenRatio = 10**18;
        uint256 TOTAL_SUPPLY = 300_000_000 * 10**18;

        uint64 emissionLockWeeks = 26;
        uint64 emissionLockDecayRate = 2;
        uint64 emissionWeeklyPct = 100;

        // weeks of automatic max-boost (TODO reduce to test boost)
        uint256 graceWeeks = 10;

        // dao
        uint256 minCreateProposalWeight = 0;
        uint256 passingPct = 30;

        //[(52, 50), (39, 70), (26, 80), (13, 90)]
        uint64[2][] memory emissionWeeklySchedule = new uint64[2][](4);
        emissionWeeklySchedule[0][0] = 52;
        emissionWeeklySchedule[0][1] = 50;
        emissionWeeklySchedule[1][0] = 39;
        emissionWeeklySchedule[1][1] = 70;
        emissionWeeklySchedule[2][0] = 26;
        emissionWeeklySchedule[2][1] = 80;
        emissionWeeklySchedule[3][0] = 13;
        emissionWeeklySchedule[3][1] = 90;

        //[2250000 * 10**18] * 4,  # initial fixed amounts
        uint128[] memory fixedInitialAmounts = new uint128[](4);
        fixedInitialAmounts[0] = 2250000 * 10**18;
        fixedInitialAmounts[1] = 2250000 * 10**18;
        fixedInitialAmounts[2] = 2250000 * 10**18;
        fixedInitialAmounts[3] = 2250000 * 10**18;

        Treasury.InitialAllowance[] memory initialAllowances = new Treasury.InitialAllowance[](1);
        initialAllowances[0] = Treasury.InitialAllowance(deployer, 90_000_000 * 10**18);


        vm.startPrank(deployer);

        addressProvider = new AddressProvider(deployer, deployer);

        mock_chainlink = new MockAggregator();
        mock_tellor = new MockTellor();
        pricefeed = new PriceFeed(address(addressProvider), address(mock_chainlink), address(mock_tellor));

        gas_pool = new GasPool();
        addressProvider.setGasPool(address(gas_pool));

        fee_receiver = new FeeReceiver(address(addressProvider));
        addressProvider.setFeeReceiver(address(fee_receiver));

        st_impl = new SortedTroves();
        addressProvider.setSortedTrovesImpl(address(st_impl));

        tm_impl = new TroveManager();
        addressProvider.setTroveManagerImpl(address(tm_impl));

        factory = new Factory(address(addressProvider));
        addressProvider.setFactory(address(factory));

        stablecoin = new Stablecoin(address(addressProvider));
        addressProvider.setStablecoin(address(stablecoin));
        
        liquidationManager = new LiquidationManager(address(addressProvider));
        addressProvider.setLiquidationManager(address(liquidationManager));

        stabilityPool = new StabilityPool(address(addressProvider));
        addressProvider.setStabilityPool(address(stabilityPool));

        borrowerOperations = new BorrowerOperations(address(addressProvider), MIN_DEBT);
        addressProvider.setBorrowerOperations(address(borrowerOperations));

        tokenLocker = new TokenLocker(address(addressProvider), lockToTokenRatio);
        addressProvider.setTokenLocker(address(tokenLocker));

        incentiveVoting = new IncentiveVoting(address(addressProvider));
        addressProvider.setIncentiveVoting(address(incentiveVoting));

        govToken = new GovToken(address(addressProvider), TOTAL_SUPPLY);
        addressProvider.setGovToken(address(govToken));

        emissionSchedule = new EmissionSchedule(address(addressProvider),emissionLockWeeks,emissionLockDecayRate,emissionWeeklyPct,emissionWeeklySchedule);
        addressProvider.setEmissionSchedule(address(emissionSchedule));

        boostCalculator = new BoostCalculator(address(addressProvider), graceWeeks);
        addressProvider.setBoostCalculator(address(boostCalculator));

        treasury = new Treasury(address(addressProvider),emissionLockWeeks,fixedInitialAmounts);
        addressProvider.setTreasury(address(treasury));

        govToken.initMintToTreasury();
        treasury.init(initialAllowances);

        adminVoting = new AdminVoting(address(addressProvider), minCreateProposalWeight, passingPct);
        addressProvider.commitTransferOwnership(address(adminVoting));
        vm.warp(block.timestamp + 86400 * 3 + 1);
        adminVoting.acceptTransferOwnership();

        vm.stopPrank();



        
        

    }



}
