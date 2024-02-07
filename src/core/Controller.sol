// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "../interfaces/IMarket.sol";
import "../interfaces/IStabilityPool.sol";
import "../interfaces/IBorrowerOperations.sol";
import "../interfaces/ISortedTroves.sol";
import "../interfaces/ILiquidationManager.sol";
import "../interfaces/IFactory.sol";
import "../interfaces/IPriceFeed.sol";
import "../interfaces/IIncentiveVoting.sol";
import "../interfaces/ITokenLocker.sol";
import "../interfaces/IBoostCalculator.sol";

/**
    @title NoFrame Core
    @notice Single source of truth for system-wide values and contract ownership.

            Ownership of this contract should be the NoFrame DAO via `AdminVoting`.
            Other ownable NoFrame contracts inherit their ownership from this contract
            using `PrismaOwnable`.
 */
contract Controller {

    uint256 public MTCR = 1100000000000000000; // 110%

    // ADDRESSES
    address public borrowerOperations;
    address public stablecoin;
    address public factory;
    address public gasPool;
    address public liquidationManager;
    address public priceFeed;
    address public stabilityPool;
    address public sortedTrovesImpl;
    address public troveManagerImpl;
    address public treasury;
    address public tokenLocker;
    address public govToken;
    address public incentiveVoting;
    address public emissionSchedule;
    address public boostCalculator;

    // ROLES
    address public owner;
    address public pendingOwner;
    address public guardian;
    address public feeReceiver;

    uint256 public ownershipTransferDeadline;


    // We enforce a three day delay between committing and applying
    // an ownership change, as a sanity check on a proposed new owner
    // and to give users time to react in case the act is malicious.
    uint256 public constant OWNERSHIP_TRANSFER_DELAY = 86400 * 3;

    // System-wide pause. When true, disables trove adjustments across all collaterals.
    bool public paused;

    // System-wide start time, rounded down the nearest epoch week.
    // Other contracts that require access to this should inherit `SystemStart`.
    uint256 public immutable startTime;

    event NewOwnerCommitted(address owner, address pendingOwner, uint256 deadline);
    event NewOwnerAccepted(address oldOwner, address owner);
    event NewOwnerRevoked(address owner, address revokedOwner);
    event FeeReceiverSet(address feeReceiver);
    event PriceFeedSet(address priceFeed);
    event GuardianSet(address guardian);
    event Paused();
    event Unpaused();
    event CollateralSunsetStarted(address collateral);

    constructor(address _owner, address _guardian) {
        owner = _owner;
        startTime = (block.timestamp / 1 weeks) * 1 weeks;
        guardian = _guardian;
        emit GuardianSet(_guardian);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    function setBorrowerOperations(address _borrowerOperations) external onlyOwner {
        require(borrowerOperations == address(0), "Setting only once");
        borrowerOperations = _borrowerOperations;
    }
    function setStablecoin(address _stablecoin) external onlyOwner {
        require(stablecoin == address(0), "Setting only once");
        stablecoin = _stablecoin;
    }
    function setFactory(address _factory) external onlyOwner {
        require(factory == address(0), "Setting only once");
        factory = _factory;
    }
    function setGasPool(address _gasPool) external onlyOwner {
        require(gasPool == address(0), "Setting only once");
        gasPool = _gasPool;
    }
    function setLiquidationManager(address _liquidationManager) external onlyOwner {
        require(liquidationManager == address(0), "Setting only once");
        liquidationManager = _liquidationManager;
    }
    /**
     * @notice Set the price feed used in the protocol
     * @param _priceFeed Price feed address
     */
    function setPriceFeed(address _priceFeed) external onlyOwner {
        require(priceFeed == address(0), "Setting only once");
        priceFeed = _priceFeed;
        emit PriceFeedSet(_priceFeed);
    }
    function setStabilityPool(address _stabilityPool) external onlyOwner {
        require(stabilityPool == address(0), "Setting only once");
        stabilityPool = _stabilityPool;
    }
    function setSortedTrovesImpl(address _sortedTrovesImpl) external onlyOwner {
        require(sortedTrovesImpl == address(0), "Setting only once");
        sortedTrovesImpl = _sortedTrovesImpl;
    }
    function setTroveManagerImpl(address _troveManagerImpl) external onlyOwner {
        require(troveManagerImpl == address(0), "Setting only once");
        troveManagerImpl = _troveManagerImpl;
    }
    function setTreasury(address _treasury) external onlyOwner {
        require(treasury == address(0), "Setting only once");
        treasury = _treasury;
    }
    function setTokenLocker(address _tokenLocker) external onlyOwner {
        require(tokenLocker == address(0), "Setting only once");
        tokenLocker = _tokenLocker;
    }

    function setGovToken(address _govToken) external onlyOwner {
        require(govToken == address(0), "Setting only once");
        govToken = _govToken;
    }
    function setIncentiveVoting(address _incentiveVoting) external onlyOwner {
        require(incentiveVoting == address(0), "Setting only once");
        incentiveVoting = _incentiveVoting;
    }
    function setEmissionSchedule(address _emissionSchedule) external onlyOwner {
        require(emissionSchedule == address(0), "Setting only once");
        emissionSchedule = _emissionSchedule;
    }
    function setBoostCalculator(address _boostCalculator) external onlyOwner {
        require(boostCalculator == address(0), "Setting only once");
        boostCalculator = _boostCalculator;
    }


    /**
     * @notice Set the receiver of all fees across the protocol
     * @param _feeReceiver Address of the fee's recipient
     */
    function setFeeReceiver(address _feeReceiver) external onlyOwner {
        feeReceiver = _feeReceiver;
        emit FeeReceiverSet(_feeReceiver);
    }

    /**
     * @notice Set the guardian address
               The guardian can execute some emergency actions
     * @param _guardian Guardian address
     */
    function setGuardian(address _guardian) external onlyOwner {
        guardian = _guardian;
        emit GuardianSet(_guardian);
    }

    /**
     * @notice Sets the global pause state of the protocol
     *         Pausing is used to mitigate risks in exceptional circumstances
     *         Functionalities affected by pausing are:
     *         - New borrowing is not possible
     *         - New collateral deposits are not possible
     *         - New stability pool deposits are not possible
     * @param _paused If true the protocol is paused
     */
    function setPaused(bool _paused) external {
        require((_paused && msg.sender == guardian) || msg.sender == owner, "Unauthorized");
        paused = _paused;
        if (_paused) {
            emit Paused();
        } else {
            emit Unpaused();
        }
    }

    /**
     * @notice Starts sunsetting a collateral
     *         During sunsetting only the following are possible:
               1) Disable collateral handoff to SP
               2) Greatly Increase interest rate to incentivize redemptions
               3) Remove redemptions fees
               4) Disable new loans
     * @param troveManager Trove manager for the collateral
     */
    function startCollateralSunset(IMarket troveManager) external onlyOwner {
        address collateral = troveManager.collateralToken();
        troveManager.startCollateralSunset();
        IStabilityPool(stabilityPool).startCollateralSunset(collateral);
        emit CollateralSunsetStarted(collateral);
    }

    function commitTransferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
        ownershipTransferDeadline = block.timestamp + OWNERSHIP_TRANSFER_DELAY;

        emit NewOwnerCommitted(msg.sender, newOwner, block.timestamp + OWNERSHIP_TRANSFER_DELAY);
    }

    function acceptTransferOwnership() external {
        require(msg.sender == pendingOwner, "Only new owner");
        require(block.timestamp >= ownershipTransferDeadline, "Deadline not passed");

        emit NewOwnerAccepted(owner, msg.sender);

        owner = pendingOwner;
        pendingOwner = address(0);
        ownershipTransferDeadline = 0;
    }

    function revokeTransferOwnership() external onlyOwner {
        emit NewOwnerRevoked(msg.sender, pendingOwner);

        pendingOwner = address(0);
        ownershipTransferDeadline = 0;
    }
}
