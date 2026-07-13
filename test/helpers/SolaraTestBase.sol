// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Test } from "forge-std/Test.sol";

import { SolaraIndexProtocol } from "../../src/SolaraIndexProtocol.sol";
import { ComponentRegistry } from "../../src/core/ComponentRegistry.sol";
import { IERC20 } from "../../src/interfaces/IERC20.sol";
import { SolaraPriceOracle } from "../../src/oracle/SolaraPriceOracle.sol";
import { SolaraIndexToken } from "../../src/token/SolaraIndexToken.sol";
import { AssetAmount, ComponentConfig, RedeemQuote } from "../../src/types/SolaraTypes.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

abstract contract SolaraTestBase is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant USDC_PRICE = 1e18;
    uint256 internal constant WETH_PRICE = 2000e18;
    uint256 internal constant WBTC_PRICE = 40_000e18;

    address internal alice;
    address internal bob;
    address internal attacker;
    address internal treasury;
    address internal keeper;

    MockERC20 internal usdc;
    MockERC20 internal weth;
    MockERC20 internal wbtc;

    SolaraPriceOracle internal oracle;
    ComponentRegistry internal registry;
    SolaraIndexProtocol internal protocol;
    SolaraIndexToken internal indexToken;

    address[] internal assets;
    uint16[] internal targetWeights;

    function setUp() public virtual {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        attacker = makeAddr("attacker");
        treasury = makeAddr("treasury");
        keeper = makeAddr("keeper");

        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        wbtc = new MockERC20("Wrapped Bitcoin", "WBTC", 8);

        oracle = new SolaraPriceOracle(address(this));
        oracle.configureFeed(address(usdc), 6, 7 days, 0.9e18, 1.1e18);
        oracle.configureFeed(address(weth), 18, 7 days, 100e18, 10_000e18);
        oracle.configureFeed(address(wbtc), 8, 7 days, 1000e18, 100_000e18);
        oracle.reportPrice(address(usdc), USDC_PRICE);
        oracle.reportPrice(address(weth), WETH_PRICE);
        oracle.reportPrice(address(wbtc), WBTC_PRICE);

        registry = new ComponentRegistry(address(this), address(oracle));
        ComponentConfig[] memory configs = new ComponentConfig[](3);
        configs[0] = ComponentConfig({
            asset: address(usdc),
            id: keccak256("USDC"),
            decimals: 6,
            weightBps: 8000,
            minWeightBps: 500,
            maxWeightBps: 9000,
            maxDeviationBps: 10_000,
            minBalance: 0,
            maxBalance: 0
        });
        configs[1] = ComponentConfig({
            asset: address(weth),
            id: keccak256("WETH"),
            decimals: 18,
            weightBps: 1000,
            minWeightBps: 500,
            maxWeightBps: 9000,
            maxDeviationBps: 10_000,
            minBalance: 0,
            maxBalance: 0
        });
        configs[2] = ComponentConfig({
            asset: address(wbtc),
            id: keccak256("WBTC"),
            decimals: 8,
            weightBps: 1000,
            minWeightBps: 500,
            maxWeightBps: 9000,
            maxDeviationBps: 10_000,
            minBalance: 0,
            maxBalance: 0
        });
        registry.listComponents(configs);

        protocol = new SolaraIndexProtocol(address(this), treasury, registry, oracle);
        registry.grantRole(registry.CONFIGURATOR_ROLE(), address(protocol));
        protocol.grantRole(protocol.REBALANCER_ROLE(), keeper);
        protocol.grantRole(protocol.GUARDIAN_ROLE(), keeper);
        protocol.grantRole(protocol.EMERGENCY_ROLE(), keeper);
        indexToken = SolaraIndexToken(protocol.indexToken());

        assets.push(address(usdc));
        assets.push(address(weth));
        assets.push(address(wbtc));
        targetWeights.push(1000);
        targetWeights.push(8000);
        targetWeights.push(1000);

        _fundAndApprove(alice);
        _fundAndApprove(bob);
        _fundAndApprove(attacker);
        _fundAndApprove(keeper);
    }

    function _fundAndApprove(
        address account
    ) internal {
        usdc.mint(account, 50_000_000e6);
        weth.mint(account, 50_000 ether);
        wbtc.mint(account, 1000e8);
        vm.startPrank(account);
        usdc.approve(address(protocol), type(uint256).max);
        weth.approve(address(protocol), type(uint256).max);
        wbtc.approve(address(protocol), type(uint256).max);
        vm.stopPrank();
    }

    function _mintIndex(
        address account,
        uint256 amount
    ) internal {
        vm.prank(account);
        protocol.mint(amount, account);
    }

    function _beginAggressiveRebalance() internal {
        vm.prank(keeper);
        protocol.beginRebalance(assets, targetWeights, 2 hours, 6 hours, 100);
    }

    function _findAmount(
        AssetAmount[] memory amounts,
        address asset
    ) internal pure returns (uint256) {
        for (uint256 i = 0; i < amounts.length; ++i) {
            if (amounts[i].asset == asset) return amounts[i].amount;
        }
        return 0;
    }

    function _findRedeemAmount(
        RedeemQuote memory quote,
        address asset
    ) internal pure returns (uint256) {
        return _findAmount(quote.withdrawals, asset);
    }
}
