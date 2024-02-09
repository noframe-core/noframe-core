// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;


interface IAggregatorV3Interface {
    function decimals() external view returns (uint8);

    function description() external view returns (string memory);

    function version() external view returns (uint256);

    // getRoundData and latestRoundData should both raise "No data present"
    // if they do not have data to report, instead of returning unset values
    // which could be misinterpreted as actual reported values.
    function getRoundData(
        uint80 _roundId
    )
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}


contract MockAggregator is IAggregatorV3Interface {
    // storage variables to hold the mock data
    uint8 private decimalsVal = 8;
    int private price;
    int private prevPrice;
    uint private updateTime;
    uint private prevUpdateTime;

    uint80 private latestRoundId;
    uint80 private prevRoundId;

    bool latestRevert;
    bool prevRevert;
    bool decimalsRevert;

    // --- Functions ---

    function setDecimals(uint8 _decimals) external {
        decimalsVal = _decimals;
    }

    function setPrice(int _price) external {
        prevPrice = price;
        price = _price;

        prevRoundId = latestRoundId;
        latestRoundId += 1;

        prevUpdateTime = updateTime;
        updateTime = block.timestamp;

    }

    function setPrevPrice(int _prevPrice) external {
        prevPrice = _prevPrice;
    }

    function setPrevUpdateTime(uint _prevUpdateTime) external {
        prevUpdateTime = _prevUpdateTime;
    }

    function setUpdateTime(uint _updateTime) external {
        updateTime = _updateTime;
    }

    function setLatestRevert() external {
        latestRevert = !latestRevert;
    }

    function setPrevRevert() external {
        prevRevert = !prevRevert;
    }

    function setDecimalsRevert() external {
        decimalsRevert = !decimalsRevert;
    }

    function setLatestRoundId(uint80 _latestRoundId) external {
        latestRoundId = _latestRoundId;
    }

    function setPrevRoundId(uint80 _prevRoundId) external {
        prevRoundId = _prevRoundId;
    }

    // --- Getters that adhere to the AggregatorV3 interface ---

    function decimals() external view override returns (uint8) {
        if (decimalsRevert) {
            require(1 == 0, "decimals reverted");
        }

        return decimalsVal;
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        if (latestRevert) {
            require(1 == 0, "latestRoundData reverted");
        }

        return (latestRoundId, price, 0, updateTime, 0);
    }

    function getRoundData(
        uint80
    )
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        if (prevRevert) {
            require(1 == 0, "getRoundData reverted");
        }

        return (prevRoundId, prevPrice, 0, updateTime, 0);
    }

    function description() external pure override returns (string memory) {
        return "";
    }

    function version() external pure override returns (uint256) {
        return 1;
    }
}


