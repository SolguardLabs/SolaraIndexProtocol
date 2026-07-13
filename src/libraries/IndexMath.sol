// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { FixedPointMath } from "./FixedPointMath.sol";

/// @title IndexMath
/// @notice NAV, decimal normalization, mint, redeem and rebalance quote helpers.
library IndexMath {
    using FixedPointMath for uint256;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    error InvalidDecimals(uint8 decimals);
    error InvalidPrice();
    error InvalidSupply();
    error InvalidWeight();
    error AmountTooSmall();

    function unit(
        uint8 decimals
    ) internal pure returns (uint256) {
        if (decimals > 36) revert InvalidDecimals(decimals);
        return 10 ** decimals;
    }

    function normalize(
        uint256 amount,
        uint8 decimals
    ) internal pure returns (uint256) {
        if (decimals == 18) return amount;
        if (decimals < 18) return amount * (10 ** (18 - decimals));
        return amount / (10 ** (decimals - 18));
    }

    function denormalize(
        uint256 amount,
        uint8 decimals
    ) internal pure returns (uint256) {
        if (decimals == 18) return amount;
        if (decimals < 18) return amount / (10 ** (18 - decimals));
        return amount * (10 ** (decimals - 18));
    }

    function denormalizeUp(
        uint256 amount,
        uint8 decimals
    ) internal pure returns (uint256) {
        if (decimals == 18) return amount;
        if (decimals < 18) return FixedPointMath.ceilDiv(amount, 10 ** (18 - decimals));
        return amount * (10 ** (decimals - 18));
    }

    function valueOf(
        uint256 amount,
        uint8 decimals,
        uint256 price
    ) internal pure returns (uint256) {
        if (price == 0) revert InvalidPrice();
        uint256 normalized = normalize(amount, decimals);
        return FixedPointMath.mulDiv(normalized, price, WAD);
    }

    function amountForValue(
        uint256 value,
        uint8 decimals,
        uint256 price
    ) internal pure returns (uint256) {
        if (price == 0) revert InvalidPrice();
        uint256 normalized = FixedPointMath.mulDivUp(value, WAD, price);
        uint256 amount = denormalizeUp(normalized, decimals);
        if (amount == 0 && value != 0) revert AmountTooSmall();
        return amount;
    }

    function mintComponentAmount(
        uint256 indexAmount,
        uint256 weightBps,
        uint8 decimals,
        uint256 price
    ) internal pure returns (uint256) {
        if (weightBps == 0 || weightBps > BPS) revert InvalidWeight();
        uint256 componentValue = FixedPointMath.mulDivUp(indexAmount, weightBps, BPS);
        return amountForValue(componentValue, decimals, price);
    }

    function fairRedeemAmount(
        uint256 componentBalance,
        uint256 shares,
        uint256 totalSupply
    ) internal pure returns (uint256) {
        if (totalSupply == 0) revert InvalidSupply();
        return FixedPointMath.mulDiv(componentBalance, shares, totalSupply);
    }

    function fairRedeemAmountUp(
        uint256 componentBalance,
        uint256 shares,
        uint256 totalSupply
    ) internal pure returns (uint256) {
        if (totalSupply == 0) revert InvalidSupply();
        return FixedPointMath.mulDivUp(componentBalance, shares, totalSupply);
    }

    function rebalanceSettlementAmount(
        uint256 componentBalance,
        uint256 shares,
        uint256 supplySnapshot,
        uint256 oldWeightBps,
        uint256 targetWeightBps
    ) internal pure returns (uint256) {
        if (supplySnapshot == 0) revert InvalidSupply();
        if (oldWeightBps == 0 || targetWeightBps == 0) revert InvalidWeight();
        uint256 baseAmount = FixedPointMath.mulDiv(componentBalance, shares, supplySnapshot);
        return FixedPointMath.mulDiv(baseAmount, targetWeightBps, oldWeightBps);
    }

    function weightedSupply(
        uint256 componentBalance,
        uint8 decimals,
        uint256 price,
        uint256 weightBps
    ) internal pure returns (uint256) {
        uint256 value = valueOf(componentBalance, decimals, price);
        return FixedPointMath.mulDiv(value, weightBps, BPS);
    }

    function pricePerShare(
        uint256 totalValue,
        uint256 totalSupply
    ) internal pure returns (uint256) {
        if (totalSupply == 0) return WAD;
        return FixedPointMath.mulDiv(totalValue, WAD, totalSupply);
    }

    function supplyForDeposit(
        uint256 depositValue,
        uint256 pricePerIndex
    ) internal pure returns (uint256) {
        if (pricePerIndex == 0) revert InvalidPrice();
        return FixedPointMath.mulDiv(depositValue, WAD, pricePerIndex);
    }

    function depositValueForSupply(
        uint256 supplyAmount,
        uint256 pricePerIndex
    ) internal pure returns (uint256) {
        if (pricePerIndex == 0) revert InvalidPrice();
        return FixedPointMath.mulDivUp(supplyAmount, pricePerIndex, WAD);
    }

    function applyHaircut(
        uint256 amount,
        uint256 haircutBps
    ) internal pure returns (uint256 net, uint256 haircut) {
        if (haircutBps > BPS) revert InvalidWeight();
        haircut = FixedPointMath.mulDiv(amount, haircutBps, BPS);
        net = amount - haircut;
    }

    function boundedMinOut(
        uint256 quotedAmount,
        uint256 slippageBps
    ) internal pure returns (uint256) {
        if (slippageBps > BPS) revert InvalidWeight();
        return quotedAmount - FixedPointMath.mulDiv(quotedAmount, slippageBps, BPS);
    }

    function isDust(
        uint256 amount,
        uint8 decimals
    ) internal pure returns (bool) {
        uint256 oneUnit = unit(decimals);
        return amount < oneUnit / 1000;
    }
}
