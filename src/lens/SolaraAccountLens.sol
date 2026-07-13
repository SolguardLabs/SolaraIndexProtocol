// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { ComponentRegistry } from "../core/ComponentRegistry.sol";
import { IERC20 } from "../interfaces/IERC20.sol";
import { ISolaraIndexProtocol } from "../interfaces/ISolaraIndexProtocol.sol";
import { FixedPointMath } from "../libraries/FixedPointMath.sol";
import { IndexMath } from "../libraries/IndexMath.sol";
import { SolaraPriceOracle } from "../oracle/SolaraPriceOracle.sol";
import { Component, RedeemQuote } from "../types/SolaraTypes.sol";

interface ISolaraAccountProtocol is ISolaraIndexProtocol {
    function fairComponentAmount(
        address asset,
        uint256 shares
    ) external view returns (uint256);
    function rebalanceComponentAmount(
        address asset,
        uint256 shares
    ) external view returns (uint256);
}

/// @title SolaraAccountLens
/// @notice Account-centric views for balances, allowances and redemption deltas.
contract SolaraAccountLens {
    uint256 public constant BPS = 10_000;
    uint256 public constant WAD = 1e18;

    struct ComponentClaim {
        address asset;
        uint256 fairAmount;
        uint256 liveAmount;
        uint256 deltaAmount;
        uint256 liveValue;
        uint256 deltaBps;
    }

    struct AccountPosition {
        address account;
        uint256 indexBalance;
        uint256 indexAllowance;
        uint256 indexValue;
        uint256 ownershipBps;
        ComponentClaim[] claims;
    }

    function accountPosition(
        address protocol,
        address account,
        address spender
    ) external view returns (AccountPosition memory position) {
        ISolaraAccountProtocol solara = ISolaraAccountProtocol(protocol);
        IERC20 index = IERC20(solara.indexToken());
        uint256 balance = index.balanceOf(account);
        uint256 totalSupply = index.totalSupply();
        ComponentClaim[] memory claims = componentClaims(protocol, balance);

        position = AccountPosition({
            account: account,
            indexBalance: balance,
            indexAllowance: index.allowance(account, spender),
            indexValue: _indexValue(solara, balance),
            ownershipBps: totalSupply == 0 ? 0 : FixedPointMath.mulDiv(balance, BPS, totalSupply),
            claims: claims
        });
    }

    function componentClaims(
        address protocol,
        uint256 shares
    ) public view returns (ComponentClaim[] memory claims) {
        ISolaraAccountProtocol solara = ISolaraAccountProtocol(protocol);
        ComponentRegistry registry = ComponentRegistry(solara.registry());
        SolaraPriceOracle oracle = SolaraPriceOracle(solara.oracle());
        RedeemQuote memory liveQuote = solara.previewRedeem(shares);
        claims = new ComponentClaim[](liveQuote.withdrawals.length);

        for (uint256 i = 0; i < liveQuote.withdrawals.length; ++i) {
            address asset = liveQuote.withdrawals[i].asset;
            uint256 fair = solara.fairComponentAmount(asset, shares);
            uint256 live = liveQuote.withdrawals[i].amount;
            Component memory component = registry.getComponent(asset);
            uint256 price = oracle.getPrice(asset);
            uint256 delta = live >= fair ? live - fair : fair - live;
            claims[i] = ComponentClaim({
                asset: asset,
                fairAmount: fair,
                liveAmount: live,
                deltaAmount: delta,
                liveValue: IndexMath.valueOf(live, component.decimals, price),
                deltaBps: fair == 0 ? 0 : FixedPointMath.mulDiv(delta, BPS, fair)
            });
        }
    }

    function redeemValueByComponent(
        address protocol,
        uint256 shares
    ) external view returns (address[] memory assets, uint256[] memory values, uint256 totalValue) {
        ISolaraAccountProtocol solara = ISolaraAccountProtocol(protocol);
        ComponentRegistry registry = ComponentRegistry(solara.registry());
        SolaraPriceOracle oracle = SolaraPriceOracle(solara.oracle());
        RedeemQuote memory quote = solara.previewRedeem(shares);
        assets = new address[](quote.withdrawals.length);
        values = new uint256[](quote.withdrawals.length);

        for (uint256 i = 0; i < quote.withdrawals.length; ++i) {
            address asset = quote.withdrawals[i].asset;
            Component memory component = registry.getComponent(asset);
            uint256 price = oracle.getPrice(asset);
            uint256 value =
                IndexMath.valueOf(quote.withdrawals[i].amount, component.decimals, price);
            assets[i] = asset;
            values[i] = value;
            totalValue += value;
        }
    }

    function largestRedeemDelta(
        address protocol,
        uint256 shares
    )
        external
        view
        returns (address asset, uint256 deltaBps, uint256 fairAmount, uint256 liveAmount)
    {
        ComponentClaim[] memory claims = componentClaims(protocol, shares);
        for (uint256 i = 0; i < claims.length; ++i) {
            if (claims[i].deltaBps > deltaBps) {
                asset = claims[i].asset;
                deltaBps = claims[i].deltaBps;
                fairAmount = claims[i].fairAmount;
                liveAmount = claims[i].liveAmount;
            }
        }
    }

    function allowanceReport(
        address protocol,
        address[] calldata owners,
        address spender
    ) external view returns (uint256[] memory balances, uint256[] memory allowances) {
        IERC20 index = IERC20(ISolaraIndexProtocol(protocol).indexToken());
        balances = new uint256[](owners.length);
        allowances = new uint256[](owners.length);
        for (uint256 i = 0; i < owners.length; ++i) {
            balances[i] = index.balanceOf(owners[i]);
            allowances[i] = index.allowance(owners[i], spender);
        }
    }

    function _indexValue(
        ISolaraIndexProtocol solara,
        uint256 balance
    ) internal view returns (uint256) {
        uint256 pricePerShare = solara.navReport().pricePerShare;
        return FixedPointMath.mulDiv(balance, pricePerShare, WAD);
    }
}
