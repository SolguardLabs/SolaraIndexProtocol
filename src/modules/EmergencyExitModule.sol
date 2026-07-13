// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { IERC20 } from "../interfaces/IERC20.sol";
import { ISolaraIndexProtocol } from "../interfaces/ISolaraIndexProtocol.sol";
import { FixedPointMath } from "../libraries/FixedPointMath.sol";
import { IndexMath } from "../libraries/IndexMath.sol";
import { AssetAmount, EmergencyState, RedeemQuote } from "../types/SolaraTypes.sol";

interface ISolaraEmergencyLike is ISolaraIndexProtocol {
    function emergencyState() external view returns (EmergencyState memory);
}

/// @title EmergencyExitModule
/// @notice Read-only helper for users preparing an emergency redemption.
contract EmergencyExitModule {
    uint256 public constant BPS = 10_000;

    error InvalidProtocol();
    error ExitWindowClosed();

    function emergencyQuote(
        address protocol,
        uint256 shares
    ) external view returns (AssetAmount[] memory netOutputs, AssetAmount[] memory haircuts) {
        if (protocol == address(0)) revert InvalidProtocol();
        ISolaraEmergencyLike solara = ISolaraEmergencyLike(protocol);
        EmergencyState memory state = solara.emergencyState();
        if (!isExitOpen(state)) revert ExitWindowClosed();

        RedeemQuote memory quote = solara.previewEmergencyRedeem(shares);
        netOutputs = new AssetAmount[](quote.withdrawals.length);
        haircuts = new AssetAmount[](quote.withdrawals.length);

        for (uint256 i = 0; i < quote.withdrawals.length; ++i) {
            (uint256 net, uint256 haircut) =
                IndexMath.applyHaircut(quote.withdrawals[i].amount, state.haircutBps);
            netOutputs[i] = AssetAmount({ asset: quote.withdrawals[i].asset, amount: net });
            haircuts[i] = AssetAmount({ asset: quote.withdrawals[i].asset, amount: haircut });
        }
    }

    function isExitOpen(
        EmergencyState memory state
    ) public view returns (bool) {
        if (!state.exitsEnabled) return false;
        if (state.expiresAt == 0) return true;
        return block.timestamp <= state.expiresAt;
    }

    function estimatedHaircutValue(
        uint256[] memory amounts,
        uint256[] memory prices,
        uint8[] memory decimals,
        uint16 haircutBps
    ) external pure returns (uint256 totalHaircutValue) {
        if (amounts.length != prices.length || amounts.length != decimals.length) {
            revert InvalidProtocol();
        }
        for (uint256 i = 0; i < amounts.length; ++i) {
            (, uint256 haircut) = IndexMath.applyHaircut(amounts[i], haircutBps);
            totalHaircutValue += IndexMath.valueOf(haircut, decimals[i], prices[i]);
        }
    }

    function minReceivedAfterHaircut(
        uint256 amount,
        uint16 haircutBps,
        uint16 userSlippageBps
    ) external pure returns (uint256) {
        (uint256 net,) = IndexMath.applyHaircut(amount, haircutBps);
        return IndexMath.boundedMinOut(net, userSlippageBps);
    }

    function vaultBalance(
        address protocol,
        address asset
    ) external view returns (uint256) {
        return IERC20(asset).balanceOf(protocol);
    }

    function redemptionShareBps(
        uint256 shares,
        uint256 totalSupply
    ) external pure returns (uint256) {
        if (totalSupply == 0) return 0;
        return FixedPointMath.mulDiv(shares, BPS, totalSupply);
    }
}
