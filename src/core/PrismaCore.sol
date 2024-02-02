// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "../interfaces/ITroveManager.sol";
import "../interfaces/IStabilityPool.sol";

/**
    @title Prisma Core
    @notice Single source of truth for system-wide values and contract ownership.

            Ownership of this contract should be the Prisma DAO via `AdminVoting`.
            Other ownable Prisma contracts inherit their ownership from this contract
            using `PrismaOwnable`.
 */
contract PrismaCore {
    IStabilityPool public immutable stabilityPool;
    address public feeReceiver;
    address public priceFeed;

    address public owner;
    address public pendingOwner;
    uint256 public ownershipTransferDeadline;

    address public guardian;

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

    constructor(address _owner, address _guardian, IStabilityPool _stabilityPool) {
        owner = _owner;
        startTime = (block.timestamp / 1 weeks) * 1 weeks;
        stabilityPool = _stabilityPool;
        guardian = _guardian;
        emit GuardianSet(_guardian);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
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
     * @notice Set the price feed used in the protocol
     * @param _priceFeed Price feed address
     */
    function setPriceFeed(address _priceFeed) external onlyOwner {
        priceFeed = _priceFeed;
        emit PriceFeedSet(_priceFeed);
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
    function startCollateralSunset(ITroveManager troveManager) external onlyOwner {
        address collateral = troveManager.collateralToken();
        troveManager.startCollateralSunset();
        stabilityPool.startCollateralSunset(collateral);
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
