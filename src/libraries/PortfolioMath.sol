// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { AssetAmount } from "../types/SolaraTypes.sol";
import { FixedPointMath } from "./FixedPointMath.sol";
import { IndexMath } from "./IndexMath.sol";
import { WeightMath } from "./WeightMath.sol";

/// @title PortfolioMath
/// @notice Array-oriented helpers for index accounting and monitoring modules.
library PortfolioMath {
    uint256 internal constant BPS = 10_000;

    error LengthMismatch();
    error EmptyPortfolio();
    error InvalidComponentValue();
    error InvalidTargetValue();

    function values(
        uint256[] memory amounts,
        uint8[] memory decimals,
        uint256[] memory prices
    ) internal pure returns (uint256[] memory componentValues, uint256 totalValue) {
        _requireSameLength(amounts.length, decimals.length);
        _requireSameLength(amounts.length, prices.length);
        if (amounts.length == 0) revert EmptyPortfolio();

        componentValues = new uint256[](amounts.length);
        for (uint256 i = 0; i < amounts.length; ++i) {
            componentValues[i] = IndexMath.valueOf(amounts[i], decimals[i], prices[i]);
            totalValue += componentValues[i];
        }
    }

    function weightsFromValues(
        uint256[] memory componentValues,
        uint256 totalValue
    ) internal pure returns (uint256[] memory weights) {
        if (componentValues.length == 0) revert EmptyPortfolio();
        weights = new uint256[](componentValues.length);
        for (uint256 i = 0; i < componentValues.length; ++i) {
            weights[i] = WeightMath.currentWeightBps(componentValues[i], totalValue);
        }
    }

    function largestDeviationFromTargets(
        uint256[] memory componentValues,
        uint16[] memory targetWeights,
        uint256 totalValue
    ) internal pure returns (uint256 largest) {
        _requireSameLength(componentValues.length, targetWeights.length);
        for (uint256 i = 0; i < componentValues.length; ++i) {
            uint256 deviation =
                WeightMath.deviationBps(componentValues[i], totalValue, targetWeights[i]);
            if (deviation > largest) largest = deviation;
        }
    }

    function proRataAmounts(
        uint256[] memory balances,
        uint256 shares,
        uint256 totalSupply
    ) internal pure returns (uint256[] memory amounts) {
        if (balances.length == 0) revert EmptyPortfolio();
        amounts = new uint256[](balances.length);
        for (uint256 i = 0; i < balances.length; ++i) {
            amounts[i] = IndexMath.fairRedeemAmount(balances[i], shares, totalSupply);
        }
    }

    function rebalanceSettlementAmounts(
        uint256[] memory balances,
        uint256 shares,
        uint256 supplySnapshot,
        uint16[] memory oldWeights,
        uint16[] memory targetWeights
    ) internal pure returns (uint256[] memory amounts) {
        _requireSameLength(balances.length, oldWeights.length);
        _requireSameLength(balances.length, targetWeights.length);
        if (balances.length == 0) revert EmptyPortfolio();
        amounts = new uint256[](balances.length);
        for (uint256 i = 0; i < balances.length; ++i) {
            amounts[i] = IndexMath.rebalanceSettlementAmount(
                balances[i], shares, supplySnapshot, oldWeights[i], targetWeights[i]
            );
        }
    }

    function componentValueAfterRedeem(
        uint256 balance,
        uint256 redeemAmount,
        uint8 decimals,
        uint256 price
    ) internal pure returns (uint256) {
        if (redeemAmount > balance) return 0;
        return IndexMath.valueOf(balance - redeemAmount, decimals, price);
    }

    function portfolioValueAfterRedeem(
        uint256[] memory balances,
        uint256[] memory redeemAmounts,
        uint8[] memory decimals,
        uint256[] memory prices
    ) internal pure returns (uint256 totalValueAfter) {
        _requireSameLength(balances.length, redeemAmounts.length);
        _requireSameLength(balances.length, decimals.length);
        _requireSameLength(balances.length, prices.length);
        for (uint256 i = 0; i < balances.length; ++i) {
            totalValueAfter += componentValueAfterRedeem(
                balances[i], redeemAmounts[i], decimals[i], prices[i]
            );
        }
    }

    function targetAmountsForValue(
        uint256 totalValue,
        uint16[] memory targetWeights,
        uint8[] memory decimals,
        uint256[] memory prices
    ) internal pure returns (uint256[] memory amounts) {
        _requireSameLength(targetWeights.length, decimals.length);
        _requireSameLength(targetWeights.length, prices.length);
        if (targetWeights.length == 0) revert EmptyPortfolio();
        amounts = new uint256[](targetWeights.length);
        for (uint256 i = 0; i < targetWeights.length; ++i) {
            uint256 targetValue = FixedPointMath.mulDiv(totalValue, targetWeights[i], BPS);
            amounts[i] = IndexMath.amountForValue(targetValue, decimals[i], prices[i]);
        }
    }

    function valueDeltas(
        uint256[] memory currentValues,
        uint16[] memory targetWeights,
        uint256 totalValue
    ) internal pure returns (int256[] memory deltas, uint256 grossTurnover) {
        _requireSameLength(currentValues.length, targetWeights.length);
        deltas = new int256[](currentValues.length);
        for (uint256 i = 0; i < currentValues.length; ++i) {
            uint256 targetValue = FixedPointMath.mulDiv(totalValue, targetWeights[i], BPS);
            if (targetValue >= currentValues[i]) {
                uint256 delta = targetValue - currentValues[i];
                deltas[i] = int256(delta);
                grossTurnover += delta;
            } else {
                uint256 delta = currentValues[i] - targetValue;
                deltas[i] = -int256(delta);
                grossTurnover += delta;
            }
        }
    }

    function basketHash(
        address[] memory assets,
        uint256[] memory balances,
        uint16[] memory weights
    ) internal pure returns (bytes32 hash) {
        _requireSameLength(assets.length, balances.length);
        _requireSameLength(assets.length, weights.length);
        hash = keccak256("SOLARA_PORTFOLIO_MATH_BASKET");
        for (uint256 i = 0; i < assets.length; ++i) {
            hash = keccak256(abi.encode(hash, assets[i], balances[i], weights[i]));
        }
    }

    function toAssetAmounts(
        address[] memory assets,
        uint256[] memory amounts
    ) internal pure returns (AssetAmount[] memory assetAmounts) {
        _requireSameLength(assets.length, amounts.length);
        assetAmounts = new AssetAmount[](assets.length);
        for (uint256 i = 0; i < assets.length; ++i) {
            assetAmounts[i] = AssetAmount({ asset: assets[i], amount: amounts[i] });
        }
    }

    function sum(
        uint256[] memory values_
    ) internal pure returns (uint256 total) {
        for (uint256 i = 0; i < values_.length; ++i) {
            total += values_[i];
        }
    }

    function _requireSameLength(
        uint256 left,
        uint256 right
    ) private pure {
        if (left != right) revert LengthMismatch();
    }
}
