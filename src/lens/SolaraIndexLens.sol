// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { ComponentRegistry } from "../core/ComponentRegistry.sol";
import { IERC20 } from "../interfaces/IERC20.sol";
import { ISolaraIndexProtocol } from "../interfaces/ISolaraIndexProtocol.sol";
import { FixedPointMath } from "../libraries/FixedPointMath.sol";
import { IndexMath } from "../libraries/IndexMath.sol";
import { WeightMath } from "../libraries/WeightMath.sol";
import { SolaraPriceOracle } from "../oracle/SolaraPriceOracle.sol";
import {
    AssetAmount,
    Component,
    ComponentReport,
    NavReport,
    RebalanceState,
    RedeemQuote,
    ValueBreakdown
} from "../types/SolaraTypes.sol";

/// @title SolaraIndexLens
/// @notice Aggregates portfolio, component and redemption views for frontends and tests.
contract SolaraIndexLens {
    uint256 public constant WAD = 1e18;

    function nav(
        address protocol
    ) external view returns (NavReport memory) {
        return ISolaraIndexProtocol(protocol).navReport();
    }

    function rebalance(
        address protocol
    ) external view returns (RebalanceState memory) {
        return ISolaraIndexProtocol(protocol).rebalanceState();
    }

    function componentReports(
        address protocol
    ) external view returns (ComponentReport[] memory reports) {
        ISolaraIndexProtocol solara = ISolaraIndexProtocol(protocol);
        ComponentRegistry registry = ComponentRegistry(solara.registry());
        SolaraPriceOracle oracle = SolaraPriceOracle(solara.oracle());
        address[] memory assets = registry.activeComponents();
        reports = new ComponentReport[](assets.length);

        uint256 totalValue;
        uint256[] memory values = new uint256[](assets.length);
        for (uint256 i = 0; i < assets.length; ++i) {
            Component memory component = registry.getComponent(assets[i]);
            uint256 balance = IERC20(assets[i]).balanceOf(protocol);
            uint256 price = oracle.getPrice(assets[i]);
            values[i] = IndexMath.valueOf(balance, component.decimals, price);
            totalValue += values[i];
        }

        for (uint256 i = 0; i < assets.length; ++i) {
            Component memory component = registry.getComponent(assets[i]);
            uint256 balance = IERC20(assets[i]).balanceOf(protocol);
            uint256 price = oracle.getPrice(assets[i]);
            reports[i] = ComponentReport({
                asset: assets[i],
                id: component.id,
                status: component.status,
                decimals: component.decimals,
                weightBps: component.weightBps,
                targetWeightBps: component.targetWeightBps,
                minWeightBps: component.minWeightBps,
                maxWeightBps: component.maxWeightBps,
                maxDeviationBps: component.maxDeviationBps,
                balance: balance,
                price: price,
                value: values[i],
                currentWeightBps: WeightMath.currentWeightBps(values[i], totalValue)
            });
        }
    }

    function valueBreakdown(
        address protocol
    ) external view returns (ValueBreakdown memory breakdown) {
        ISolaraIndexProtocol solara = ISolaraIndexProtocol(protocol);
        ComponentRegistry registry = ComponentRegistry(solara.registry());
        SolaraPriceOracle oracle = SolaraPriceOracle(solara.oracle());
        address[] memory assets = registry.activeComponents();
        uint256[] memory values = new uint256[](assets.length);
        uint16[] memory weights = new uint16[](assets.length);
        uint256 totalValue;

        for (uint256 i = 0; i < assets.length; ++i) {
            Component memory component = registry.getComponent(assets[i]);
            weights[i] = component.weightBps;
            uint256 balance = IERC20(assets[i]).balanceOf(protocol);
            uint256 price = oracle.getPrice(assets[i]);
            values[i] = IndexMath.valueOf(balance, component.decimals, price);
            totalValue += values[i];
        }

        NavReport memory report = solara.navReport();
        breakdown = ValueBreakdown({
            grossValue: totalValue,
            indexSupply: report.totalSupply,
            valuePerIndex: IndexMath.pricePerShare(totalValue, report.totalSupply),
            componentCount: assets.length,
            staleComponents: 0,
            largestDeviationBps: WeightMath.largestDeviation(values, weights, totalValue)
        });
    }

    function previewRedeemByAsset(
        address protocol,
        uint256 shares,
        address desiredAsset
    ) external view returns (uint256 amount, uint256 index) {
        RedeemQuote memory quote = ISolaraIndexProtocol(protocol).previewRedeem(shares);
        for (uint256 i = 0; i < quote.withdrawals.length; ++i) {
            if (quote.withdrawals[i].asset == desiredAsset) {
                return (quote.withdrawals[i].amount, i);
            }
        }
        return (0, type(uint256).max);
    }

    function previewRedeemValues(
        address protocol,
        uint256 shares
    )
        external
        view
        returns (AssetAmount[] memory outputs, uint256[] memory values, uint256 totalValue)
    {
        ISolaraIndexProtocol solara = ISolaraIndexProtocol(protocol);
        ComponentRegistry registry = ComponentRegistry(solara.registry());
        SolaraPriceOracle oracle = SolaraPriceOracle(solara.oracle());
        RedeemQuote memory quote = solara.previewRedeem(shares);
        outputs = quote.withdrawals;
        values = new uint256[](outputs.length);
        for (uint256 i = 0; i < outputs.length; ++i) {
            Component memory component = registry.getComponent(outputs[i].asset);
            uint256 price = oracle.getPrice(outputs[i].asset);
            values[i] = IndexMath.valueOf(outputs[i].amount, component.decimals, price);
            totalValue += values[i];
        }
    }

    function accountIndexValue(
        address protocol,
        address account
    ) external view returns (uint256) {
        ISolaraIndexProtocol solara = ISolaraIndexProtocol(protocol);
        NavReport memory report = solara.navReport();
        uint256 balance = IERC20(solara.indexToken()).balanceOf(account);
        return FixedPointMath.mulDiv(balance, report.pricePerShare, WAD);
    }
}
