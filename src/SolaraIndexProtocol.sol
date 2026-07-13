// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { ProtocolAccess } from "./access/ProtocolAccess.sol";
import { ComponentRegistry } from "./core/ComponentRegistry.sol";
import { ReentrancyLock } from "./core/ReentrancyLock.sol";
import { IERC20 } from "./interfaces/IERC20.sol";
import { ISolaraIndexProtocol } from "./interfaces/ISolaraIndexProtocol.sol";
import { FixedPointMath } from "./libraries/FixedPointMath.sol";
import { IndexMath } from "./libraries/IndexMath.sol";
import { SafeTransferLib } from "./libraries/SafeTransferLib.sol";
import { WeightMath } from "./libraries/WeightMath.sol";
import { SolaraPriceOracle } from "./oracle/SolaraPriceOracle.sol";
import { SolaraIndexToken } from "./token/SolaraIndexToken.sol";
import {
    AssetAmount,
    Component,
    ComponentSnapshot,
    ComponentStatus,
    EmergencyState,
    MintQuote,
    NavReport,
    RebalanceState,
    RebalanceStatus,
    RedeemQuote
} from "./types/SolaraTypes.sol";

/// @title SolaraIndexProtocol
/// @notice Basket minting, redemption and rebalance settlement protocol for Solara index tokens.
contract SolaraIndexProtocol is ProtocolAccess, ReentrancyLock, ISolaraIndexProtocol {
    using SafeTransferLib for address;
    using FixedPointMath for uint256;

    uint256 public constant BPS = 10_000;
    uint256 public constant WAD = 1e18;
    uint40 public constant DEFAULT_TRADING_WINDOW = 2 hours;
    uint40 public constant DEFAULT_SETTLEMENT_WINDOW = 6 hours;

    ComponentRegistry public immutable componentRegistry;
    SolaraPriceOracle public immutable priceOracle;
    SolaraIndexToken private immutable _indexToken;

    address public treasury;
    bool public protocolPaused;

    RebalanceState private _rebalance;
    EmergencyState private _emergency;

    address[] private _rebalanceAssets;
    mapping(uint64 nonce => mapping(address asset => uint16 weightBps)) private _oldWeightByNonce;
    mapping(uint64 nonce => mapping(address asset => uint16 weightBps)) private
        _targetWeightByNonce;

    error InvalidAmount();
    error InvalidReceiver();
    error ProtocolPaused();
    error RebalanceActive(uint64 nonce);
    error RebalanceNotActive();
    error InvalidRebalanceState(RebalanceStatus status);
    error InvalidRebalanceWindow();
    error InvalidTrade();
    error ComponentUnavailable(address asset);
    error InsufficientVaultBalance(address asset, uint256 balance, uint256 requested);
    error BalanceCapExceeded(address asset, uint256 balance, uint256 cap);
    error BalanceBelowMinimum(address asset, uint256 balance, uint256 minimum);
    error EmergencyExitUnavailable();
    error EmergencyExitExpired(uint256 nowTime, uint256 expiresAt);
    error UnexpectedTokenBalance(address asset, uint256 expected, uint256 received);
    error NumericOverflow(uint256 value);

    constructor(
        address initialAdmin,
        address initialTreasury,
        ComponentRegistry initialRegistry,
        SolaraPriceOracle initialOracle
    ) ProtocolAccess(initialAdmin) {
        if (initialTreasury == address(0)) revert ZeroAddress();
        if (address(initialRegistry) == address(0) || address(initialOracle) == address(0)) {
            revert ZeroAddress();
        }
        treasury = initialTreasury;
        componentRegistry = initialRegistry;
        priceOracle = initialOracle;
        _indexToken = new SolaraIndexToken("Solara Index Token", "SINDEX", address(this));
        emit TreasuryUpdated(address(0), initialTreasury);
    }

    modifier whenOperational() {
        if (protocolPaused) revert ProtocolPaused();
        _;
    }

    // -------------------------------------------------------------------------
    // User operations
    // -------------------------------------------------------------------------

    function mint(
        uint256 indexAmount,
        address receiver
    ) external override nonReentrant whenOperational returns (uint256 minted) {
        if (indexAmount == 0) revert InvalidAmount();
        if (receiver == address(0)) revert InvalidReceiver();
        if (_rebalance.status != RebalanceStatus.Idle) revert RebalanceActive(_rebalance.nonce);

        MintQuote memory quote = _previewMint(indexAmount);
        for (uint256 i = 0; i < quote.deposits.length; ++i) {
            AssetAmount memory deposit = quote.deposits[i];
            _pullExact(deposit.asset, msg.sender, deposit.amount);
        }

        _validatePostMintBalances(quote.deposits);
        _indexToken.mint(receiver, indexAmount);
        minted = indexAmount;

        emit Minted(msg.sender, receiver, minted, quote.deposits.length);
    }

    function redeem(
        uint256 shares,
        address receiver
    ) external override nonReentrant returns (AssetAmount[] memory outputs) {
        if (shares == 0) revert InvalidAmount();
        if (receiver == address(0)) revert InvalidReceiver();

        RedeemQuote memory quote = _previewRedeem(shares);
        _indexToken.burn(msg.sender, shares);
        _transferOutputs(receiver, quote.withdrawals);
        emit Redeemed(msg.sender, receiver, shares, quote.withdrawals.length, quote.duringRebalance);
        return quote.withdrawals;
    }

    function emergencyRedeem(
        uint256 shares,
        address receiver
    ) external override nonReentrant returns (AssetAmount[] memory outputs) {
        if (shares == 0) revert InvalidAmount();
        if (receiver == address(0)) revert InvalidReceiver();
        if (!_emergency.exitsEnabled) revert EmergencyExitUnavailable();
        if (_emergency.expiresAt != 0 && block.timestamp > _emergency.expiresAt) {
            revert EmergencyExitExpired(block.timestamp, _emergency.expiresAt);
        }

        RedeemQuote memory quote = _previewFairRedeem(shares);
        outputs = new AssetAmount[](quote.withdrawals.length);
        uint256 totalHaircutValue;
        address haircutReceiver = _emergency.receiver == address(0) ? treasury : _emergency.receiver;

        _indexToken.burn(msg.sender, shares);
        for (uint256 i = 0; i < quote.withdrawals.length; ++i) {
            AssetAmount memory withdrawal = quote.withdrawals[i];
            (uint256 net, uint256 haircut) =
                IndexMath.applyHaircut(withdrawal.amount, _emergency.haircutBps);
            outputs[i] = AssetAmount({ asset: withdrawal.asset, amount: net });
            if (net != 0) withdrawal.asset.safeTransfer(receiver, net);
            if (haircut != 0) {
                withdrawal.asset.safeTransfer(haircutReceiver, haircut);
                Component memory component = componentRegistry.getComponent(withdrawal.asset);
                uint256 price = priceOracle.getPrice(withdrawal.asset);
                totalHaircutValue += IndexMath.valueOf(haircut, component.decimals, price);
            }
        }

        emit EmergencyRedeemed(msg.sender, receiver, shares, totalHaircutValue, outputs.length);
    }

    // -------------------------------------------------------------------------
    // Rebalance lifecycle
    // -------------------------------------------------------------------------

    function beginRebalance(
        address[] calldata assets,
        uint16[] calldata targetWeights,
        uint40 tradingWindow,
        uint40 settlementWindow,
        uint16 maxTradeSlippageBps
    ) external onlyRole(REBALANCER_ROLE) whenOperational {
        if (_rebalance.status != RebalanceStatus.Idle) revert RebalanceActive(_rebalance.nonce);
        WeightMath.validateWeights(assets, targetWeights);
        if (tradingWindow == 0) tradingWindow = DEFAULT_TRADING_WINDOW;
        if (settlementWindow == 0) settlementWindow = DEFAULT_SETTLEMENT_WINDOW;
        if (maxTradeSlippageBps > BPS) revert InvalidRebalanceWindow();

        uint64 nonce = _rebalance.nonce + 1;
        _clearRebalanceAssets();
        uint256 valueSnapshot = _snapshotRebalanceComponents(nonce, assets, targetWeights);

        componentRegistry.setTargetWeights(assets, targetWeights);

        bytes32 hash = _rebalanceComponentHash(nonce, assets);
        _writeRebalanceState(
            nonce, tradingWindow, settlementWindow, maxTradeSlippageBps, valueSnapshot, hash
        );

        emit RebalanceStarted(nonce, msg.sender, _rebalance.supplySnapshot, valueSnapshot, hash);
    }

    function moveRebalanceToTrading() external onlyRole(REBALANCER_ROLE) {
        if (_rebalance.status != RebalanceStatus.Announced) {
            revert InvalidRebalanceState(_rebalance.status);
        }
        _setRebalanceStatus(RebalanceStatus.Trading);
    }

    function openRebalanceSettlement() external onlyRole(REBALANCER_ROLE) {
        if (
            _rebalance.status != RebalanceStatus.Announced
                && _rebalance.status != RebalanceStatus.Trading
        ) {
            revert InvalidRebalanceState(_rebalance.status);
        }
        _setRebalanceStatus(RebalanceStatus.Settlement);
    }

    function executeRebalanceTrade(
        address assetOut,
        address assetIn,
        uint256 amountOut,
        uint256 amountIn,
        address counterparty
    ) external nonReentrant onlyRole(REBALANCER_ROLE) {
        if (_rebalance.status != RebalanceStatus.Trading) {
            revert InvalidRebalanceState(_rebalance.status);
        }
        if (
            assetOut == address(0) || assetIn == address(0) || assetOut == assetIn || amountOut == 0
                || amountIn == 0 || counterparty == address(0)
        ) revert InvalidTrade();

        _requireRebalanceAsset(assetOut);
        _requireRebalanceAsset(assetIn);
        _validateVaultBalance(assetOut, amountOut);

        assetOut.safeTransfer(counterparty, amountOut);
        _pullExact(assetIn, counterparty, amountIn);
        emit RebalanceTradeExecuted(_rebalance.nonce, assetOut, assetIn, amountOut, amountIn);
    }

    function finalizeRebalance() external onlyRole(REBALANCER_ROLE) whenOperational {
        if (
            _rebalance.status != RebalanceStatus.Announced
                && _rebalance.status != RebalanceStatus.Trading
                && _rebalance.status != RebalanceStatus.Settlement
        ) {
            revert InvalidRebalanceState(_rebalance.status);
        }

        address[] memory assets = new address[](_rebalanceAssets.length);
        uint16[] memory weights = new uint16[](_rebalanceAssets.length);
        for (uint256 i = 0; i < _rebalanceAssets.length; ++i) {
            assets[i] = _rebalanceAssets[i];
            weights[i] = _targetWeightByNonce[_rebalance.nonce][assets[i]];
        }

        _validateFinalBalances(assets, weights);
        componentRegistry.applyTargetWeights(assets, weights);

        uint64 nonce = _rebalance.nonce;
        bytes32 hash = componentRegistry.componentHash();
        _rebalance.status = RebalanceStatus.Idle;
        _rebalance.componentHash = hash;
        _clearRebalanceAssets();

        emit RebalanceFinalized(nonce, hash);
        emit RebalanceStatusUpdated(nonce, RebalanceStatus.Settlement, RebalanceStatus.Idle);
    }

    function cancelRebalance() external onlyRole(GUARDIAN_ROLE) {
        if (_rebalance.status == RebalanceStatus.Idle) revert RebalanceNotActive();
        uint64 nonce = _rebalance.nonce;
        _setRebalanceStatus(RebalanceStatus.Cancelled);
        _rebalance.status = RebalanceStatus.Idle;
        _clearRebalanceAssets();
        emit RebalanceCancelled(nonce, msg.sender);
    }

    // -------------------------------------------------------------------------
    // Emergency and administration
    // -------------------------------------------------------------------------

    function setProtocolPaused(
        bool paused
    ) external onlyRole(GUARDIAN_ROLE) {
        protocolPaused = paused;
        emit ProtocolPauseUpdated(paused);
    }

    function setTreasury(
        address newTreasury
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newTreasury == address(0)) revert ZeroAddress();
        address previous = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(previous, newTreasury);
    }

    function enableEmergencyExits(
        uint16 haircutBps,
        uint40 duration,
        address receiver
    ) external onlyRole(EMERGENCY_ROLE) {
        if (haircutBps > BPS) revert InvalidAmount();
        protocolPaused = true;
        _rebalance.status = RebalanceStatus.Emergency;
        _emergency = EmergencyState({
            exitsEnabled: true,
            haircutBps: haircutBps,
            enabledAt: _toUint40(block.timestamp),
            expiresAt: duration == 0 ? 0 : _toUint40(block.timestamp + duration),
            receiver: receiver == address(0) ? treasury : receiver
        });
        emit ProtocolPauseUpdated(true);
        emit EmergencyExitEnabled(haircutBps, _emergency.expiresAt, _emergency.receiver);
    }

    function disableEmergencyExits() external onlyRole(EMERGENCY_ROLE) {
        _emergency.exitsEnabled = false;
        _rebalance.status = RebalanceStatus.Idle;
        emit EmergencyExitDisabled();
    }

    function sweepDust(
        address asset,
        uint256 amount,
        address receiver
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (receiver == address(0) || amount == 0) revert InvalidAmount();
        Component memory component = componentRegistry.getComponent(asset);
        uint256 balance = IERC20(asset).balanceOf(address(this));
        if (balance - amount < component.minBalance) {
            revert BalanceBelowMinimum(asset, balance - amount, component.minBalance);
        }
        asset.safeTransfer(receiver, amount);
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function indexToken() external view override returns (address) {
        return address(_indexToken);
    }

    function registry() external view override returns (address) {
        return address(componentRegistry);
    }

    function oracle() external view override returns (address) {
        return address(priceOracle);
    }

    function rebalanceState() external view override returns (RebalanceState memory state) {
        return _rebalance;
    }

    function emergencyState() external view returns (EmergencyState memory state) {
        return _emergency;
    }

    function rebalanceAssetCount() external view returns (uint256) {
        return _rebalanceAssets.length;
    }

    function rebalanceAssetAt(
        uint256 index
    ) external view returns (address) {
        return _rebalanceAssets[index];
    }

    function rebalanceWeights(
        uint64 nonce,
        address asset
    ) external view returns (uint16 oldWeightBps, uint16 targetWeightBps) {
        return (_oldWeightByNonce[nonce][asset], _targetWeightByNonce[nonce][asset]);
    }

    function previewMint(
        uint256 indexAmount
    ) external view override returns (MintQuote memory quote) {
        return _previewMint(indexAmount);
    }

    function previewRedeem(
        uint256 shares
    ) external view override returns (RedeemQuote memory quote) {
        return _previewRedeem(shares);
    }

    function previewEmergencyRedeem(
        uint256 shares
    ) external view returns (RedeemQuote memory quote) {
        return _previewFairRedeem(shares);
    }

    function navReport() external view override returns (NavReport memory report) {
        uint256 totalValue = _totalPortfolioValue();
        uint256 supply = _indexToken.totalSupply();
        report = NavReport({
            totalValue: totalValue,
            totalSupply: supply,
            pricePerShare: IndexMath.pricePerShare(totalValue, supply),
            timestamp: block.timestamp,
            componentHash: componentRegistry.componentHash()
        });
    }

    function componentSnapshots() external view returns (ComponentSnapshot[] memory snapshots) {
        address[] memory assets = componentRegistry.activeComponents();
        snapshots = new ComponentSnapshot[](assets.length);
        for (uint256 i = 0; i < assets.length; ++i) {
            Component memory component = componentRegistry.getComponent(assets[i]);
            uint256 balance = IERC20(assets[i]).balanceOf(address(this));
            uint256 price = priceOracle.getPrice(assets[i]);
            snapshots[i] = ComponentSnapshot({
                asset: assets[i],
                oldWeightBps: component.weightBps,
                targetWeightBps: component.targetWeightBps,
                decimals: component.decimals,
                balance: balance,
                price: price
            });
        }
    }

    function totalPortfolioValue() external view returns (uint256) {
        return _totalPortfolioValue();
    }

    function fairComponentAmount(
        address asset,
        uint256 shares
    ) external view returns (uint256) {
        uint256 supply = _indexToken.totalSupply();
        uint256 balance = IERC20(asset).balanceOf(address(this));
        return IndexMath.fairRedeemAmount(balance, shares, supply);
    }

    function rebalanceComponentAmount(
        address asset,
        uint256 shares
    ) external view returns (uint256) {
        if (_rebalance.status == RebalanceStatus.Idle) revert RebalanceNotActive();
        uint16 oldWeight = _oldWeightByNonce[_rebalance.nonce][asset];
        uint16 targetWeight = _targetWeightByNonce[_rebalance.nonce][asset];
        uint256 balance = IERC20(asset).balanceOf(address(this));
        return IndexMath.rebalanceSettlementAmount(
            balance, shares, _rebalance.supplySnapshot, oldWeight, targetWeight
        );
    }

    // -------------------------------------------------------------------------
    // Internal quote paths
    // -------------------------------------------------------------------------

    function _previewMint(
        uint256 indexAmount
    ) internal view returns (MintQuote memory quote) {
        if (indexAmount == 0) revert InvalidAmount();
        address[] memory assets = componentRegistry.activeComponents();
        AssetAmount[] memory deposits = new AssetAmount[](assets.length);
        uint256 totalValue;

        for (uint256 i = 0; i < assets.length; ++i) {
            Component memory component = componentRegistry.getComponent(assets[i]);
            uint256 price = priceOracle.getPrice(assets[i]);
            uint256 amount = IndexMath.mintComponentAmount(
                indexAmount, component.weightBps, component.decimals, price
            );
            deposits[i] = AssetAmount({ asset: assets[i], amount: amount });
            totalValue += IndexMath.valueOf(amount, component.decimals, price);
        }

        quote = MintQuote({
            indexAmount: indexAmount,
            totalValue: totalValue,
            componentCount: assets.length,
            deposits: deposits
        });
    }

    function _previewRedeem(
        uint256 shares
    ) internal view returns (RedeemQuote memory quote) {
        if (shares == 0) revert InvalidAmount();
        if (_rebalance.status == RebalanceStatus.Idle) {
            return _previewFairRedeem(shares);
        }
        return _previewRebalanceRedeem(shares);
    }

    function _previewFairRedeem(
        uint256 shares
    ) internal view returns (RedeemQuote memory quote) {
        uint256 supply = _indexToken.totalSupply();
        address[] memory assets = componentRegistry.activeComponents();
        AssetAmount[] memory withdrawals = new AssetAmount[](assets.length);
        uint256 totalValue;

        for (uint256 i = 0; i < assets.length; ++i) {
            Component memory component = componentRegistry.getComponent(assets[i]);
            uint256 balance = IERC20(assets[i]).balanceOf(address(this));
            uint256 amount = IndexMath.fairRedeemAmount(balance, shares, supply);
            uint256 price = priceOracle.getPrice(assets[i]);
            withdrawals[i] = AssetAmount({ asset: assets[i], amount: amount });
            totalValue += IndexMath.valueOf(amount, component.decimals, price);
        }

        quote = RedeemQuote({
            shares: shares,
            supplyUsed: supply,
            totalValue: totalValue,
            duringRebalance: false,
            withdrawals: withdrawals
        });
    }

    function _previewRebalanceRedeem(
        uint256 shares
    ) internal view returns (RedeemQuote memory quote) {
        address[] memory assets = _copyRebalanceAssets();
        AssetAmount[] memory withdrawals = new AssetAmount[](assets.length);
        uint256 totalValue;

        for (uint256 i = 0; i < assets.length; ++i) {
            address asset = assets[i];
            uint16 oldWeight = _oldWeightByNonce[_rebalance.nonce][asset];
            uint16 targetWeight = _targetWeightByNonce[_rebalance.nonce][asset];
            uint256 balance = IERC20(asset).balanceOf(address(this));
            uint256 amount = IndexMath.rebalanceSettlementAmount(
                balance, shares, _rebalance.supplySnapshot, oldWeight, targetWeight
            );
            Component memory component = componentRegistry.getComponent(asset);
            uint256 price = priceOracle.getPrice(asset);
            withdrawals[i] = AssetAmount({ asset: asset, amount: amount });
            totalValue += IndexMath.valueOf(amount, component.decimals, price);
        }

        quote = RedeemQuote({
            shares: shares,
            supplyUsed: _rebalance.supplySnapshot,
            totalValue: totalValue,
            duringRebalance: true,
            withdrawals: withdrawals
        });
    }

    // -------------------------------------------------------------------------
    // Internal settlement helpers
    // -------------------------------------------------------------------------

    function _transferOutputs(
        address receiver,
        AssetAmount[] memory outputs
    ) internal {
        for (uint256 i = 0; i < outputs.length; ++i) {
            _validateVaultBalance(outputs[i].asset, outputs[i].amount);
            if (outputs[i].amount != 0) outputs[i].asset.safeTransfer(receiver, outputs[i].amount);
        }
    }

    function _pullExact(
        address asset,
        address payer,
        uint256 amount
    ) internal {
        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));
        asset.safeTransferFrom(payer, address(this), amount);
        uint256 received = IERC20(asset).balanceOf(address(this)) - balanceBefore;
        if (received != amount) revert UnexpectedTokenBalance(asset, amount, received);
    }

    function _validateVaultBalance(
        address asset,
        uint256 amount
    ) internal view {
        uint256 balance = IERC20(asset).balanceOf(address(this));
        if (amount > balance) revert InsufficientVaultBalance(asset, balance, amount);
    }

    function _validatePostMintBalances(
        AssetAmount[] memory deposits
    ) internal view {
        for (uint256 i = 0; i < deposits.length; ++i) {
            Component memory component = componentRegistry.getComponent(deposits[i].asset);
            uint256 balance = IERC20(deposits[i].asset).balanceOf(address(this));
            if (component.maxBalance != 0 && balance > component.maxBalance) {
                revert BalanceCapExceeded(deposits[i].asset, balance, component.maxBalance);
            }
        }
    }

    function _validateFinalBalances(
        address[] memory assets,
        uint16[] memory weights
    ) internal view {
        uint256 totalValue = _totalPortfolioValue();
        for (uint256 i = 0; i < assets.length; ++i) {
            Component memory component = componentRegistry.getComponent(assets[i]);
            uint256 balance = IERC20(assets[i]).balanceOf(address(this));
            if (balance < component.minBalance) {
                revert BalanceBelowMinimum(assets[i], balance, component.minBalance);
            }
            if (component.maxBalance != 0 && balance > component.maxBalance) {
                revert BalanceCapExceeded(assets[i], balance, component.maxBalance);
            }
            uint256 price = priceOracle.getPrice(assets[i]);
            uint256 value = IndexMath.valueOf(balance, component.decimals, price);
            WeightMath.assertDeviation(
                assets[i], value, totalValue, weights[i], component.maxDeviationBps
            );
        }
    }

    function _requireRebalanceAsset(
        address asset
    ) internal view {
        for (uint256 i = 0; i < _rebalanceAssets.length; ++i) {
            if (_rebalanceAssets[i] == asset) return;
        }
        revert ComponentUnavailable(asset);
    }

    function _totalPortfolioValue() internal view returns (uint256 totalValue) {
        address[] memory assets = componentRegistry.activeComponents();
        for (uint256 i = 0; i < assets.length; ++i) {
            Component memory component = componentRegistry.getComponent(assets[i]);
            uint256 balance = IERC20(assets[i]).balanceOf(address(this));
            uint256 price = priceOracle.getPrice(assets[i]);
            totalValue += IndexMath.valueOf(balance, component.decimals, price);
        }
    }

    function _setRebalanceStatus(
        RebalanceStatus nextStatus
    ) internal {
        RebalanceStatus previous = _rebalance.status;
        _rebalance.status = nextStatus;
        emit RebalanceStatusUpdated(_rebalance.nonce, previous, nextStatus);
    }

    function _copyRebalanceAssets() internal view returns (address[] memory assets) {
        assets = new address[](_rebalanceAssets.length);
        for (uint256 i = 0; i < _rebalanceAssets.length; ++i) {
            assets[i] = _rebalanceAssets[i];
        }
    }

    function _clearRebalanceAssets() internal {
        while (_rebalanceAssets.length != 0) {
            _rebalanceAssets.pop();
        }
    }

    function _snapshotRebalanceComponents(
        uint64 nonce,
        address[] calldata assets,
        uint16[] calldata targetWeights
    ) internal returns (uint256 valueSnapshot) {
        for (uint256 i = 0; i < assets.length; ++i) {
            Component memory component = componentRegistry.getComponent(assets[i]);
            if (component.status != ComponentStatus.Active) revert ComponentUnavailable(assets[i]);
            WeightMath.validateWeightRange(
                assets[i], targetWeights[i], component.minWeightBps, component.maxWeightBps
            );
            uint256 balance = IERC20(assets[i]).balanceOf(address(this));
            uint256 price = priceOracle.getPrice(assets[i]);
            valueSnapshot += IndexMath.valueOf(balance, component.decimals, price);
            _oldWeightByNonce[nonce][assets[i]] = component.weightBps;
            _targetWeightByNonce[nonce][assets[i]] = targetWeights[i];
            _rebalanceAssets.push(assets[i]);
        }
    }

    function _writeRebalanceState(
        uint64 nonce,
        uint40 tradingWindow,
        uint40 settlementWindow,
        uint16 maxTradeSlippageBps,
        uint256 valueSnapshot,
        bytes32 hash
    ) internal {
        _rebalance = RebalanceState({
            status: RebalanceStatus.Announced,
            nonce: nonce,
            startedAt: _toUint40(block.timestamp),
            tradingEndsAt: _toUint40(block.timestamp + tradingWindow),
            settlementEndsAt: _toUint40(block.timestamp + tradingWindow + settlementWindow),
            maxTradeSlippageBps: maxTradeSlippageBps,
            emergencyDiscountBps: 0,
            supplySnapshot: _indexToken.totalSupply(),
            totalValueSnapshot: valueSnapshot,
            componentHash: hash,
            initiatedBy: msg.sender
        });
    }

    function _rebalanceComponentHash(
        uint64 nonce,
        address[] calldata assets
    ) internal view returns (bytes32) {
        bytes32 rolling = keccak256(abi.encode("SOLARA_REBALANCE_COMPONENTS", nonce));
        for (uint256 i = 0; i < assets.length; ++i) {
            rolling = keccak256(
                abi.encode(
                    rolling,
                    assets[i],
                    _oldWeightByNonce[nonce][assets[i]],
                    _targetWeightByNonce[nonce][assets[i]]
                )
            );
        }
        return rolling;
    }

    function _toUint40(
        uint256 value
    ) internal pure returns (uint40) {
        if (value > type(uint40).max) revert NumericOverflow(value);
        return uint40(value);
    }
}
