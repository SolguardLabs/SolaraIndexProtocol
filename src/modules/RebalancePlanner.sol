// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { ComponentRegistry } from "../core/ComponentRegistry.sol";
import { IERC20 } from "../interfaces/IERC20.sol";
import { FixedPointMath } from "../libraries/FixedPointMath.sol";
import { IndexMath } from "../libraries/IndexMath.sol";
import { WeightMath } from "../libraries/WeightMath.sol";
import { SolaraPriceOracle } from "../oracle/SolaraPriceOracle.sol";
import { Component, TradeIntent } from "../types/SolaraTypes.sol";

/// @title RebalancePlanner
/// @notice Read-only planning helper for target allocations and trade deltas.
contract RebalancePlanner {
    uint256 public constant BPS = 10_000;

    ComponentRegistry public immutable registry;
    SolaraPriceOracle public immutable oracle;
    address public immutable vault;

    error InvalidTargetSet();
    error InvalidSlippage(uint16 basisPoints);

    constructor(
        ComponentRegistry initialRegistry,
        SolaraPriceOracle initialOracle,
        address initialVault
    ) {
        registry = initialRegistry;
        oracle = initialOracle;
        vault = initialVault;
    }

    function currentPlan() external view returns (TradeIntent[] memory intents) {
        address[] memory assets = registry.activeComponents();
        uint16[] memory weights = new uint16[](assets.length);
        for (uint256 i = 0; i < assets.length; ++i) {
            weights[i] = registry.getComponent(assets[i]).targetWeightBps;
        }
        return planForWeights(assets, weights);
    }

    function planForWeights(
        address[] memory assets,
        uint16[] memory targetWeights
    ) public view returns (TradeIntent[] memory intents) {
        WeightMath.validateWeights(assets, targetWeights);
        uint256 totalValue = portfolioValue(assets);
        intents = new TradeIntent[](assets.length);

        for (uint256 i = 0; i < assets.length; ++i) {
            Component memory component = registry.getComponent(assets[i]);
            uint256 balance = IERC20(assets[i]).balanceOf(vault);
            uint256 price = oracle.getPrice(assets[i]);
            uint256 currentValue = IndexMath.valueOf(balance, component.decimals, price);
            uint256 targetValue = FixedPointMath.mulDiv(totalValue, targetWeights[i], BPS);
            uint256 currentWeight = WeightMath.currentWeightBps(currentValue, totalValue);
            int256 delta;
            uint256 absolute;
            if (targetValue >= currentValue) {
                absolute = targetValue - currentValue;
                delta = int256(absolute);
            } else {
                absolute = currentValue - targetValue;
                delta = -int256(absolute);
            }
            intents[i] = TradeIntent({
                asset: assets[i],
                currentValue: currentValue,
                targetValue: targetValue,
                currentWeightBps: currentWeight,
                targetWeightBps: targetWeights[i],
                valueDelta: delta,
                absoluteDelta: absolute
            });
        }
    }

    function componentTradeAmount(
        address asset,
        uint256 valueDelta
    ) external view returns (uint256 amount) {
        Component memory component = registry.getComponent(asset);
        uint256 price = oracle.getPrice(asset);
        return IndexMath.amountForValue(valueDelta, component.decimals, price);
    }

    function portfolioValue(
        address[] memory assets
    ) public view returns (uint256 totalValue) {
        for (uint256 i = 0; i < assets.length; ++i) {
            Component memory component = registry.getComponent(assets[i]);
            uint256 balance = IERC20(assets[i]).balanceOf(vault);
            uint256 price = oracle.getPrice(assets[i]);
            totalValue += IndexMath.valueOf(balance, component.decimals, price);
        }
    }

    function targetTokenAmounts(
        address[] memory assets,
        uint16[] memory targetWeights
    ) external view returns (uint256[] memory amounts) {
        WeightMath.validateWeights(assets, targetWeights);
        uint256 totalValue = portfolioValue(assets);
        amounts = new uint256[](assets.length);
        for (uint256 i = 0; i < assets.length; ++i) {
            Component memory component = registry.getComponent(assets[i]);
            uint256 price = oracle.getPrice(assets[i]);
            uint256 targetValue = FixedPointMath.mulDiv(totalValue, targetWeights[i], BPS);
            amounts[i] = IndexMath.amountForValue(targetValue, component.decimals, price);
        }
    }

    function projectedDeviation(
        address[] memory assets,
        uint16[] memory targetWeights
    ) external view returns (uint256 largestDeviationBps) {
        TradeIntent[] memory intents = planForWeights(assets, targetWeights);
        for (uint256 i = 0; i < intents.length; ++i) {
            uint256 deviation =
                FixedPointMath.absDiff(intents[i].currentWeightBps, intents[i].targetWeightBps);
            if (deviation > largestDeviationBps) largestDeviationBps = deviation;
        }
    }

    function executionBounds(
        address asset,
        uint256 valueDelta,
        uint16 slippageBps
    ) external view returns (uint256 nominal, uint256 minimumReceive, uint256 maximumSpend) {
        if (slippageBps > BPS) revert InvalidSlippage(slippageBps);
        Component memory component = registry.getComponent(asset);
        uint256 price = oracle.getPrice(asset);
        nominal = IndexMath.amountForValue(valueDelta, component.decimals, price);
        minimumReceive = FixedPointMath.mulDiv(nominal, BPS - slippageBps, BPS);
        maximumSpend = FixedPointMath.mulDivUp(nominal, BPS + slippageBps, BPS);
    }
}
