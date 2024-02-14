// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "../interfaces/IAggregatorV3Interface.sol";
import "../dependencies/PrismaMath.sol";
import "./Controller.sol";

/**
    @title NoFrame Default Price Feed
    @notice Based on Liquity's PriceFeed:
            https://github.com/liquity/dev/blob/main/packages/contracts/contracts/PriceFeed.sol

            NoFrame's implementation additionally multiplies the oracle price by the underlying
            collateral's share price. This is sufficient for pricing the most dominant LSTs at
            the time of writing this contract (wstETH, rETH). In some cases this approach may
            be insufficient and so a custom oracle may be required.
 */
abstract contract OracleChainlink {
    
    uint256 public constant DECIMAL_PRECISION = 1e18;

    // Use to convert a price answer to an 18-digit precision uint256
    uint256 public constant TARGET_DIGITS = 18;

    // In the unlikely event that Chainlink updates their oracle to change the
    // decimal precision, this contract will have to be redeployed and updated
    // by protocol governance
    uint256 public constant CHAINLINK_DIGITS = 8;

    // Maximum time period allowed since Chainlink's latest round data timestamp, beyond which Chainlink is considered frozen.
    uint256 public constant TIMEOUT = 14400; // 4 hours: 60 * 60 * 4

    // Maximum deviation allowed between two consecutive Chainlink oracle prices. 18-digit precision.
    uint256 public constant MAX_PRICE_DEVIATION_FROM_PREVIOUS_ROUND = 5e17; // 50%

    // The last good price seen from an oracle by NoFrame
    mapping (address => uint128) public lastGoodPrices;
    mapping (address => uint80) public chainlinkLatestRounds;
    mapping (address => uint32) public lastUpdates;

    // The current status of the PricFeed, which determines the conditions for the next price fetch attempt
    mapping (address => Status) public status;
    enum Status {
        chainlinkWorking,
        chainlinkUntrusted,
        chainlinkFrozen
    }

    struct ChainlinkResponse {
        uint80 roundId;
        int256 answer;
        uint256 timestamp;
        bool success;
    }

    event PriceFeedStatusChanged(Status newStatus);
    event LastGoodPriceUpdated(uint256 _lastGoodPrice);
    event SharePriceDataSet(address collateral);

    constructor() {}

    /**
        @notice Get the latest price returned from the oracle
        @dev If the caller is a `MarketCore` with a share price function set,
             the oracle price is multiplied by the share price. You can obtain
             these values by calling `MarketCore.fetchPrice()` rather than
             directly interacting with this contract.
     */
    function priceChainlink(address _chainlinkAggregator) public returns (uint256 price) {

        uint128 lastGoodPrice = lastGoodPrices[_chainlinkAggregator];
        uint32 lastUpdated = lastUpdates[_chainlinkAggregator];

        // if calling first time
        if (lastUpdates[_chainlinkAggregator] == 0) {
            status[_chainlinkAggregator] = Status.chainlinkWorking;
            ChainlinkResponse memory chainlinkResponse = _getCurrentChainlinkResponse(_chainlinkAggregator);
            _storeChainlinkPrice(chainlinkResponse, _chainlinkAggregator);
        }

        price = lastGoodPrice;
        if (lastUpdated < block.timestamp) {
            lastUpdated = uint32(block.timestamp);
            price = _updateChainlinkPrice(lastGoodPrice, _chainlinkAggregator);
        }
        return price;
    }

    function _updateChainlinkPrice(uint256 lastPrice, address _chainlinkAggregator) internal returns (uint256 price) {
        Status _status = status[_chainlinkAggregator];
        // Get current and previous price data from Chainlink
        ChainlinkResponse memory chainlinkResponse = _getCurrentChainlinkResponse(_chainlinkAggregator);

        if (
            chainlinkResponse.roundId == chainlinkLatestRounds[_chainlinkAggregator] &&
            _status == Status.chainlinkWorking &&
            !_chainlinkIsFrozen(chainlinkResponse)
        ) {
            // If Chainlink is working, the returned round ID is equal to the last seen one,
            // and the response is not stale, we can use the last stored price
            return lastPrice;
        }

        ChainlinkResponse memory prevChainlinkResponse = _getPrevChainlinkResponse(_chainlinkAggregator, chainlinkResponse.roundId);

        // --- CASE 1: System fetched last price from Chainlink  ---
        if (_status == Status.chainlinkWorking) {

            if (_chainlinkIsBroken(chainlinkResponse, prevChainlinkResponse)) {
                _changeStatus(_chainlinkAggregator, Status.chainlinkUntrusted);
                return lastPrice;
            }

            // If Chainlink price has changed by > 50% between two consecutive rounds
            if (_chainlinkPriceChangeAboveMax(chainlinkResponse, prevChainlinkResponse)) {
                _changeStatus(_chainlinkAggregator, Status.chainlinkUntrusted);
                return lastPrice;
            }

            if (_chainlinkIsFrozen(chainlinkResponse)) {
                _changeStatus(_chainlinkAggregator, Status.chainlinkFrozen);
                return lastPrice;
            }

            // If Chainlink is working, return Chainlink current price (no status change)
            return _storeChainlinkPrice(chainlinkResponse, _chainlinkAggregator);
        }

        // --- CASE 2: Chainlink untrusted ---
        if (_status == Status.chainlinkUntrusted) {
            /*
             * If both oracles are now live, unbroken and similar price, we assume that they are reporting
             * accurately, and so we switch back to Chainlink.
             */
            if (_isNotBrokenNotFrozen(chainlinkResponse, prevChainlinkResponse)) {
                _changeStatus(_chainlinkAggregator, Status.chainlinkWorking);
                return _storeChainlinkPrice(chainlinkResponse, _chainlinkAggregator);
            }
            // Otherwise, return the last good price - oracles is still untrusted (no status change)
            return lastPrice;
        }

        // --- CASE 3: Chainlink frozen ---
        if (_status == Status.chainlinkFrozen) {
            // If Chainlink breaks, now both oracles are untrusted
            if (_isNotBrokenNotFrozen(chainlinkResponse, prevChainlinkResponse)) {
                _changeStatus(_chainlinkAggregator, Status.chainlinkWorking);
                return _storeChainlinkPrice(chainlinkResponse, _chainlinkAggregator);
            }
            // Otherwise, return the last good price - oracles is still untrusted (no status change)
            return lastPrice;
        }
    }

    // --- Helper functions ---

    /* Chainlink is considered broken if its current or previous round data is in any way bad. We check the previous round
     * for two reasons:
     *
     * 1) It is necessary data for the price deviation check in case 1,
     * and
     * 2) Chainlink is the PriceFeed's preferred primary oracle - having two consecutive valid round responses adds
     * peace of mind when using or returning to Chainlink.
     */
    function _chainlinkIsBroken(
        ChainlinkResponse memory _currentResponse,
        ChainlinkResponse memory _prevResponse
    ) internal view returns (bool) {
        return _badChainlinkResponse(_currentResponse) || _badChainlinkResponse(_prevResponse);
    }

    function _badChainlinkResponse(ChainlinkResponse memory _response) internal view returns (bool) {
        // Check for response call reverted
        if (!_response.success) {
            return true;
        }
        // Check for an invalid roundId that is 0
        if (_response.roundId == 0) {
            return true;
        }
        // Check for an invalid timeStamp that is 0, or in the future
        if (_response.timestamp == 0 || _response.timestamp > block.timestamp) {
            return true;
        }
        // Check for non-positive price
        if (_response.answer <= 0) {
            return true;
        }

        return false;
    }

    function _chainlinkIsFrozen(ChainlinkResponse memory _response) internal view returns (bool) {
        return block.timestamp - _response.timestamp > TIMEOUT;
    }

    function _chainlinkPriceChangeAboveMax(
        ChainlinkResponse memory _currentResponse,
        ChainlinkResponse memory _prevResponse
    ) internal pure returns (bool) {
        uint256 currentScaledPrice = _scaleChainlinkPriceByDigits(_currentResponse.answer);
        uint256 prevScaledPrice = _scaleChainlinkPriceByDigits(_prevResponse.answer);

        uint256 minPrice = PrismaMath._min(currentScaledPrice, prevScaledPrice);
        uint256 maxPrice = PrismaMath._max(currentScaledPrice, prevScaledPrice);

        /*
         * Use the larger price as the denominator:
         * - If price decreased, the percentage deviation is in relation to the the previous price.
         * - If price increased, the percentage deviation is in relation to the current price.
         */
        uint256 percentDeviation = ((maxPrice - minPrice) * DECIMAL_PRECISION) / maxPrice;

        // Return true if price has more than doubled, or more than halved.
        return percentDeviation > MAX_PRICE_DEVIATION_FROM_PREVIOUS_ROUND;
    }

    function _isNotBrokenNotFrozen(
        ChainlinkResponse memory _chainlinkResponse,
        ChainlinkResponse memory _prevChainlinkResponse
    ) internal view returns (bool) {
        // Return false if oracle is broken or frozen
        if (
            _chainlinkIsBroken(_chainlinkResponse, _prevChainlinkResponse) ||
            _chainlinkIsFrozen(_chainlinkResponse)
        ) {
            return false;
        }

        return true;
    }

    function _scaleChainlinkPriceByDigits(int256 _price) internal pure returns (uint256) {
        return uint256(_price) * (10 ** (TARGET_DIGITS - CHAINLINK_DIGITS));
    }

    function _changeStatus(address _chainlinkAggregator, Status _status) internal {
        status[_chainlinkAggregator] = _status;
        emit PriceFeedStatusChanged(_status);
    }


    function _storeChainlinkPrice(ChainlinkResponse memory _chainlinkResponse, address _chainlinkAggregator) internal returns (uint256) {
        uint256 scaledChainlinkPrice = _scaleChainlinkPriceByDigits(_chainlinkResponse.answer);
        lastGoodPrices[_chainlinkAggregator] = uint128(scaledChainlinkPrice);
        chainlinkLatestRounds[_chainlinkAggregator] = _chainlinkResponse.roundId;

        emit LastGoodPriceUpdated(scaledChainlinkPrice);
        return scaledChainlinkPrice;
    }

    // --- Oracle response wrapper functions ---

    function _getCurrentChainlinkResponse(address _priceAggregator) internal view returns (ChainlinkResponse memory chainlinkResponse) {
        // Try to get latest price data:
        try IAggregatorV3Interface(_priceAggregator).latestRoundData() returns (
            uint80 roundId,
            int256 answer,
            uint256 /* startedAt */,
            uint256 timestamp,
            uint80 /* answeredInRound */
        ) {
            // If call to Chainlink succeeds, return the response and success = true
            chainlinkResponse.roundId = roundId;
            chainlinkResponse.answer = answer;
            chainlinkResponse.timestamp = timestamp;
            chainlinkResponse.success = true;
            return chainlinkResponse;
        } catch {
            // If call to Chainlink aggregator reverts, return a zero response with success = false
            return chainlinkResponse;
        }
    }

    function _getPrevChainlinkResponse(
            address _priceAggregator, 
            uint80 _currentRoundId
    ) internal view returns (ChainlinkResponse memory prevChainlinkResponse) {
        if (_currentRoundId < 1) return prevChainlinkResponse;

        // Try to get the price data from the previous round:
        try IAggregatorV3Interface(_priceAggregator).getRoundData(_currentRoundId - 1) returns (
            uint80 roundId,
            int256 answer,
            uint256 /* startedAt */,
            uint256 timestamp,
            uint80 /* answeredInRound */
        ) {
            // If call to Chainlink succeeds, return the response and success = true
            prevChainlinkResponse.roundId = roundId;
            prevChainlinkResponse.answer = answer;
            prevChainlinkResponse.timestamp = timestamp;
            prevChainlinkResponse.success = true;
            return prevChainlinkResponse;
        } catch {
            // If call to Chainlink aggregator reverts, return a zero response with success = false
            return prevChainlinkResponse;
        }
    }
}
