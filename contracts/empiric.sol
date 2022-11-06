// MyOracle.sol

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

interface IOracle {
    enum AggregationMode {
        MEDIAN
    }

    function getSpot(
        bytes32 pairId,
        AggregationMode,
        bytes32[] memory sources
    )
        external
        view
        returns (
            uint256 price,
            uint256 decimals,
            uint256 lastUpdatedTimestamp,
            uint256 numSourcesAggregated
        );
}

contract MyOracle {
    IOracle public oracle;
    bytes32[] public sources;

    constructor(address _oracle, bytes32[] memory _sources) {
        oracle = IOracle(_oracle);
        sources = _sources;
    }

    function getPrice(bytes32 _pairId) public view returns (uint256 price) {
        (
            uint256 _price,
            ,
            uint256 _lastUpdatedTimestamp,
            uint256 _numSourcesAggregated
        ) = oracle.getSpot(_pairId, IOracle.AggregationMode.MEDIAN, sources);
        require(_numSourcesAggregated > 1, "must use at least two sources");
        require(_lastUpdatedTimestamp > block.timestamp - 3600, "update stale");
        return _price;
    }
}