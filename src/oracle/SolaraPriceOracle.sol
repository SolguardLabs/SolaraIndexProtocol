// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { ProtocolAccess } from "../access/ProtocolAccess.sol";
import { PriceFeed } from "../types/SolaraTypes.sol";

/// @title SolaraPriceOracle
/// @notice Admin-reported 18-decimal asset prices with heartbeat and bounds.
contract SolaraPriceOracle is ProtocolAccess {
    mapping(address asset => PriceFeed feed) private _feeds;
    address[] private _assets;

    error InvalidAsset(address asset);
    error InvalidFeedConfiguration();
    error InvalidPrice(uint256 price);
    error FeedNotConfigured(address asset);
    error FeedPaused(address asset);
    error StalePrice(address asset, uint256 updatedAt, uint256 heartbeat);
    error NumericOverflow(uint256 value);

    event FeedConfigured(
        address indexed asset, uint8 decimals, uint40 heartbeat, uint128 minPrice, uint128 maxPrice
    );
    event PriceReported(address indexed asset, uint256 price, uint40 updatedAt);
    event FeedPauseUpdated(address indexed asset, bool paused);

    constructor(
        address initialAdmin
    ) ProtocolAccess(initialAdmin) { }

    function configureFeed(
        address asset,
        uint8 assetDecimals,
        uint40 heartbeat,
        uint128 minPrice,
        uint128 maxPrice
    ) external onlyRole(CONFIGURATOR_ROLE) {
        if (asset == address(0) || asset.code.length == 0) revert InvalidAsset(asset);
        if (assetDecimals > 36 || heartbeat == 0 || minPrice == 0 || maxPrice < minPrice) {
            revert InvalidFeedConfiguration();
        }

        PriceFeed storage feed = _feeds[asset];
        if (!feed.configured) _assets.push(asset);
        feed.configured = true;
        feed.assetDecimals = assetDecimals;
        feed.heartbeat = heartbeat;
        feed.minPrice = minPrice;
        feed.maxPrice = maxPrice;

        emit FeedConfigured(asset, assetDecimals, heartbeat, minPrice, maxPrice);
    }

    function reportPrice(
        address asset,
        uint256 price
    ) external onlyRole(ORACLE_REPORTER_ROLE) {
        PriceFeed storage feed = _requireFeed(asset);
        _validatePrice(feed, price);
        feed.price = price;
        feed.updatedAt = _toUint40(block.timestamp);
        emit PriceReported(asset, price, feed.updatedAt);
    }

    function reportPrices(
        address[] calldata assets,
        uint256[] calldata prices
    ) external onlyRole(ORACLE_REPORTER_ROLE) {
        if (assets.length != prices.length) revert InvalidFeedConfiguration();
        for (uint256 i = 0; i < assets.length; ++i) {
            PriceFeed storage feed = _requireFeed(assets[i]);
            _validatePrice(feed, prices[i]);
            feed.price = prices[i];
            feed.updatedAt = _toUint40(block.timestamp);
            emit PriceReported(assets[i], prices[i], feed.updatedAt);
        }
    }

    function setFeedPaused(
        address asset,
        bool paused
    ) external onlyRole(GUARDIAN_ROLE) {
        PriceFeed storage feed = _requireFeed(asset);
        feed.paused = paused;
        emit FeedPauseUpdated(asset, paused);
    }

    function getPrice(
        address asset
    ) external view returns (uint256) {
        PriceFeed storage feed = _requireFeedView(asset);
        _requireLive(asset, feed);
        return feed.price;
    }

    function getPriceUnsafe(
        address asset
    ) external view returns (uint256) {
        return _requireFeedView(asset).price;
    }

    function getFeed(
        address asset
    ) external view returns (PriceFeed memory) {
        return _requireFeedView(asset);
    }

    function feedCount() external view returns (uint256) {
        return _assets.length;
    }

    function feedAt(
        uint256 index
    ) external view returns (address) {
        return _assets[index];
    }

    function isFresh(
        address asset
    ) external view returns (bool) {
        PriceFeed storage feed = _requireFeedView(asset);
        if (feed.paused || feed.price == 0) return false;
        return block.timestamp <= uint256(feed.updatedAt) + feed.heartbeat;
    }

    function assertFresh(
        address asset
    ) external view returns (uint256 price) {
        PriceFeed storage feed = _requireFeedView(asset);
        _requireLive(asset, feed);
        return feed.price;
    }

    function _requireFeed(
        address asset
    ) internal view returns (PriceFeed storage feed) {
        feed = _feeds[asset];
        if (!feed.configured) revert FeedNotConfigured(asset);
    }

    function _requireFeedView(
        address asset
    ) internal view returns (PriceFeed storage feed) {
        feed = _feeds[asset];
        if (!feed.configured) revert FeedNotConfigured(asset);
    }

    function _requireLive(
        address asset,
        PriceFeed storage feed
    ) internal view {
        if (feed.paused) revert FeedPaused(asset);
        if (feed.price == 0) revert InvalidPrice(0);
        if (block.timestamp > uint256(feed.updatedAt) + feed.heartbeat) {
            revert StalePrice(asset, feed.updatedAt, feed.heartbeat);
        }
    }

    function _validatePrice(
        PriceFeed storage feed,
        uint256 price
    ) internal view {
        if (price < feed.minPrice || price > feed.maxPrice) revert InvalidPrice(price);
    }

    function _toUint40(
        uint256 value
    ) internal pure returns (uint40) {
        if (value > type(uint40).max) revert NumericOverflow(value);
        return uint40(value);
    }
}
