// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {
    AssetAmount,
    MintQuote,
    NavReport,
    RebalanceState,
    RebalanceStatus,
    RedeemQuote
} from "../types/SolaraTypes.sol";

interface ISolaraIndexProtocol {
    event Minted(
        address indexed payer, address indexed receiver, uint256 indexAmount, uint256 componentCount
    );
    event Redeemed(
        address indexed owner,
        address indexed receiver,
        uint256 shares,
        uint256 componentCount,
        bool duringRebalance
    );
    event RebalanceStarted(
        uint64 indexed nonce,
        address indexed initiator,
        uint256 supplySnapshot,
        uint256 valueSnapshot,
        bytes32 componentHash
    );
    event RebalanceStatusUpdated(
        uint64 indexed nonce, RebalanceStatus previousStatus, RebalanceStatus nextStatus
    );
    event RebalanceFinalized(uint64 indexed nonce, bytes32 componentHash);
    event RebalanceCancelled(uint64 indexed nonce, address indexed caller);
    event EmergencyExitEnabled(uint16 haircutBps, uint40 expiresAt, address indexed receiver);
    event EmergencyExitDisabled();
    event EmergencyRedeemed(
        address indexed owner,
        address indexed receiver,
        uint256 shares,
        uint256 haircutValue,
        uint256 componentCount
    );
    event TreasuryUpdated(address indexed previousTreasury, address indexed newTreasury);
    event ProtocolPauseUpdated(bool paused);
    event RebalanceTradeExecuted(
        uint64 indexed nonce,
        address indexed assetOut,
        address indexed assetIn,
        uint256 amountOut,
        uint256 amountIn
    );

    function mint(
        uint256 indexAmount,
        address receiver
    ) external returns (uint256 minted);
    function redeem(
        uint256 shares,
        address receiver
    ) external returns (AssetAmount[] memory outputs);
    function emergencyRedeem(
        uint256 shares,
        address receiver
    ) external returns (AssetAmount[] memory outputs);
    function previewMint(
        uint256 indexAmount
    ) external view returns (MintQuote memory quote);
    function previewRedeem(
        uint256 shares
    ) external view returns (RedeemQuote memory quote);
    function previewEmergencyRedeem(
        uint256 shares
    ) external view returns (RedeemQuote memory quote);
    function navReport() external view returns (NavReport memory report);
    function rebalanceState() external view returns (RebalanceState memory state);
    function indexToken() external view returns (address);
    function registry() external view returns (address);
    function oracle() external view returns (address);
}
