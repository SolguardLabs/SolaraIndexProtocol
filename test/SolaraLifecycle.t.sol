// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {
    AssetAmount,
    Component,
    RebalanceState,
    RebalanceStatus,
    RedeemQuote
} from "../src/types/SolaraTypes.sol";
import { SolaraTestBase } from "./helpers/SolaraTestBase.sol";

contract SolaraLifecycleTest is SolaraTestBase {
    function testMintPullsWeightedBasketAndMintsIndex() public {
        uint256 mintAmount = 1000 ether;
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 aliceWethBefore = weth.balanceOf(alice);
        uint256 aliceWbtcBefore = wbtc.balanceOf(alice);

        _mintIndex(alice, mintAmount);

        assertEq(indexToken.balanceOf(alice), mintAmount);
        assertEq(aliceUsdcBefore - usdc.balanceOf(alice), 800_000_000);
        assertEq(aliceWethBefore - weth.balanceOf(alice), 0.05 ether);
        assertEq(aliceWbtcBefore - wbtc.balanceOf(alice), 250_000);
    }

    function testRedeemOutsideRebalanceUsesFairProRataBalances() public {
        _mintIndex(alice, 1000 ether);
        _mintIndex(bob, 500 ether);

        uint256 shares = 150 ether;
        uint256 fairUsdc = protocol.fairComponentAmount(address(usdc), shares);
        uint256 fairWeth = protocol.fairComponentAmount(address(weth), shares);
        uint256 fairWbtc = protocol.fairComponentAmount(address(wbtc), shares);

        uint256 usdcBefore = usdc.balanceOf(bob);
        uint256 wethBefore = weth.balanceOf(bob);
        uint256 wbtcBefore = wbtc.balanceOf(bob);

        vm.prank(bob);
        protocol.redeem(shares, bob);

        assertEq(usdc.balanceOf(bob) - usdcBefore, fairUsdc);
        assertEq(weth.balanceOf(bob) - wethBefore, fairWeth);
        assertEq(wbtc.balanceOf(bob) - wbtcBefore, fairWbtc);
        assertEq(indexToken.balanceOf(bob), 350 ether);
    }

    function testBeginAndFinalizeRebalanceUpdatesWeights() public {
        _mintIndex(alice, 1000 ether);
        _beginAggressiveRebalance();

        RebalanceState memory state = protocol.rebalanceState();
        assertEq(uint256(state.status), uint256(RebalanceStatus.Announced));
        assertEq(state.supplySnapshot, 1000 ether);

        vm.prank(keeper);
        protocol.openRebalanceSettlement();
        vm.prank(keeper);
        protocol.finalizeRebalance();

        Component memory usdcComponent = registry.getComponent(address(usdc));
        Component memory wethComponent = registry.getComponent(address(weth));
        Component memory wbtcComponent = registry.getComponent(address(wbtc));
        assertEq(usdcComponent.weightBps, 1000);
        assertEq(wethComponent.weightBps, 8000);
        assertEq(wbtcComponent.weightBps, 1000);
        assertEq(uint256(protocol.rebalanceState().status), uint256(RebalanceStatus.Idle));
    }

    function testEmergencyExitUsesFairProRataEvenWhenProtocolPaused() public {
        _mintIndex(alice, 1000 ether);
        _mintIndex(bob, 1000 ether);

        uint256 shares = 200 ether;
        RedeemQuote memory quote = protocol.previewEmergencyRedeem(shares);
        uint256 quotedUsdc = _findRedeemAmount(quote, address(usdc));
        uint256 quotedWeth = _findRedeemAmount(quote, address(weth));

        vm.prank(keeper);
        protocol.enableEmergencyExits(250, 1 days, treasury);

        uint256 usdcBefore = usdc.balanceOf(alice);
        uint256 wethBefore = weth.balanceOf(alice);
        uint256 treasuryUsdcBefore = usdc.balanceOf(treasury);

        vm.prank(alice);
        protocol.emergencyRedeem(shares, alice);

        assertEq(usdc.balanceOf(alice) - usdcBefore, quotedUsdc * 9750 / 10_000);
        assertEq(weth.balanceOf(alice) - wethBefore, quotedWeth * 9750 / 10_000);
        assertEq(usdc.balanceOf(treasury) - treasuryUsdcBefore, quotedUsdc * 250 / 10_000);
    }
}
