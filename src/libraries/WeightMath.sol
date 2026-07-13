// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { FixedPointMath } from "./FixedPointMath.sol";

/// @title WeightMath
/// @notice Helpers for validating and comparing component weights.
library WeightMath {
    using FixedPointMath for uint256;

    uint256 internal constant BPS = 10_000;

    error EmptyWeights();
    error InvalidWeight(address asset, uint256 weightBps);
    error DuplicateAsset(address asset);
    error WeightSumMismatch(uint256 sum);
    error WeightOutOfRange(
        address asset, uint256 weightBps, uint256 minWeightBps, uint256 maxWeightBps
    );
    error DeviationExceeded(address asset, uint256 deviationBps, uint256 maxDeviationBps);

    function validateWeights(
        address[] memory assets,
        uint16[] memory weights
    ) internal pure {
        if (assets.length == 0 || assets.length != weights.length) revert EmptyWeights();
        uint256 sum;
        for (uint256 i = 0; i < assets.length; ++i) {
            if (assets[i] == address(0) || weights[i] == 0) {
                revert InvalidWeight(assets[i], weights[i]);
            }
            sum += weights[i];
            for (uint256 j = i + 1; j < assets.length; ++j) {
                if (assets[i] == assets[j]) revert DuplicateAsset(assets[i]);
            }
        }
        if (sum != BPS) revert WeightSumMismatch(sum);
    }

    function validateWeightRange(
        address asset,
        uint256 weightBps,
        uint256 minWeightBps,
        uint256 maxWeightBps
    ) internal pure {
        if (minWeightBps > maxWeightBps || maxWeightBps > BPS) {
            revert WeightOutOfRange(asset, weightBps, minWeightBps, maxWeightBps);
        }
        if (weightBps < minWeightBps || weightBps > maxWeightBps) {
            revert WeightOutOfRange(asset, weightBps, minWeightBps, maxWeightBps);
        }
    }

    function currentWeightBps(
        uint256 componentValue,
        uint256 totalValue
    ) internal pure returns (uint256) {
        if (totalValue == 0) return 0;
        return FixedPointMath.mulDiv(componentValue, BPS, totalValue);
    }

    function deviationBps(
        uint256 componentValue,
        uint256 totalValue,
        uint256 targetWeightBps
    ) internal pure returns (uint256) {
        uint256 current = currentWeightBps(componentValue, totalValue);
        return current.absDiff(targetWeightBps);
    }

    function assertDeviation(
        address asset,
        uint256 componentValue,
        uint256 totalValue,
        uint256 targetWeightBps,
        uint256 maxDeviationBps
    ) internal pure {
        uint256 deviation = deviationBps(componentValue, totalValue, targetWeightBps);
        if (deviation > maxDeviationBps) {
            revert DeviationExceeded(asset, deviation, maxDeviationBps);
        }
    }

    function largestDeviation(
        uint256[] memory values,
        uint16[] memory weights,
        uint256 totalValue
    ) internal pure returns (uint256 largest) {
        if (values.length != weights.length) revert EmptyWeights();
        for (uint256 i = 0; i < values.length; ++i) {
            uint256 deviation = deviationBps(values[i], totalValue, weights[i]);
            if (deviation > largest) largest = deviation;
        }
    }

    function scaleWeight(
        uint256 amount,
        uint256 fromWeightBps,
        uint256 toWeightBps
    ) internal pure returns (uint256) {
        if (fromWeightBps == 0) revert InvalidWeight(address(0), fromWeightBps);
        return FixedPointMath.mulDiv(amount, toWeightBps, fromWeightBps);
    }

    function weightedAverage(
        uint256 left,
        uint256 leftWeightBps,
        uint256 right,
        uint256 rightWeightBps
    ) internal pure returns (uint256) {
        uint256 denominator = leftWeightBps + rightWeightBps;
        if (denominator == 0) revert InvalidWeight(address(0), 0);
        return FixedPointMath.mulDiv(left, leftWeightBps, denominator)
            + FixedPointMath.mulDiv(right, rightWeightBps, denominator);
    }
}
