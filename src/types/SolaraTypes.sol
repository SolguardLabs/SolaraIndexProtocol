// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Lifecycle status for a listed component.
enum ComponentStatus {
    Unlisted,
    Active,
    Frozen,
    Disabled
}

/// @notice Rebalance state machine used by the main protocol.
enum RebalanceStatus {
    Idle,
    Announced,
    Trading,
    Settlement,
    Cancelled,
    Emergency
}

/// @notice Persistent configuration for one component token.
struct Component {
    address asset;
    bytes32 id;
    ComponentStatus status;
    uint8 decimals;
    uint16 weightBps;
    uint16 targetWeightBps;
    uint16 minWeightBps;
    uint16 maxWeightBps;
    uint16 maxDeviationBps;
    uint40 listedAt;
    uint40 updatedAt;
    uint128 minBalance;
    uint128 maxBalance;
}

/// @notice Input object used when a component is listed.
struct ComponentConfig {
    address asset;
    bytes32 id;
    uint8 decimals;
    uint16 weightBps;
    uint16 minWeightBps;
    uint16 maxWeightBps;
    uint16 maxDeviationBps;
    uint128 minBalance;
    uint128 maxBalance;
}

/// @notice Compact report returned by the registry and lens.
struct ComponentReport {
    address asset;
    bytes32 id;
    ComponentStatus status;
    uint8 decimals;
    uint16 weightBps;
    uint16 targetWeightBps;
    uint16 minWeightBps;
    uint16 maxWeightBps;
    uint16 maxDeviationBps;
    uint256 balance;
    uint256 price;
    uint256 value;
    uint256 currentWeightBps;
}

/// @notice Amount for a single asset.
struct AssetAmount {
    address asset;
    uint256 amount;
}

/// @notice Mint quote for a desired index amount.
struct MintQuote {
    uint256 indexAmount;
    uint256 totalValue;
    uint256 componentCount;
    AssetAmount[] deposits;
}

/// @notice Redemption quote for index shares.
struct RedeemQuote {
    uint256 shares;
    uint256 supplyUsed;
    uint256 totalValue;
    bool duringRebalance;
    AssetAmount[] withdrawals;
}

/// @notice Weight update packed for governance and rebalance payloads.
struct WeightUpdate {
    address asset;
    uint16 weightBps;
}

/// @notice Snapshot of one component at rebalance start.
struct ComponentSnapshot {
    address asset;
    uint16 oldWeightBps;
    uint16 targetWeightBps;
    uint8 decimals;
    uint256 balance;
    uint256 price;
}

/// @notice Aggregate rebalance state.
struct RebalanceState {
    RebalanceStatus status;
    uint64 nonce;
    uint40 startedAt;
    uint40 tradingEndsAt;
    uint40 settlementEndsAt;
    uint16 maxTradeSlippageBps;
    uint16 emergencyDiscountBps;
    uint256 supplySnapshot;
    uint256 totalValueSnapshot;
    bytes32 componentHash;
    address initiatedBy;
}

/// @notice Value breakdown used by the lens and invariant tests.
struct ValueBreakdown {
    uint256 grossValue;
    uint256 indexSupply;
    uint256 valuePerIndex;
    uint256 componentCount;
    uint256 staleComponents;
    uint256 largestDeviationBps;
}

/// @notice Oracle feed configuration.
struct PriceFeed {
    bool configured;
    bool paused;
    uint8 assetDecimals;
    uint40 heartbeat;
    uint40 updatedAt;
    uint128 minPrice;
    uint128 maxPrice;
    uint256 price;
}

/// @notice Emergency exit controls.
struct EmergencyState {
    bool exitsEnabled;
    uint16 haircutBps;
    uint40 enabledAt;
    uint40 expiresAt;
    address receiver;
}

/// @notice Rebalance planner output for a component.
struct TradeIntent {
    address asset;
    uint256 currentValue;
    uint256 targetValue;
    uint256 currentWeightBps;
    uint256 targetWeightBps;
    int256 valueDelta;
    uint256 absoluteDelta;
}

/// @notice Portfolio quote for reporting.
struct NavReport {
    uint256 totalValue;
    uint256 totalSupply;
    uint256 pricePerShare;
    uint256 timestamp;
    bytes32 componentHash;
}
