// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { Script } from "forge-std/Script.sol";

import { SolaraIndexProtocol } from "../src/SolaraIndexProtocol.sol";
import { ComponentRegistry } from "../src/core/ComponentRegistry.sol";
import { SolaraPriceOracle } from "../src/oracle/SolaraPriceOracle.sol";

contract DeploySolara is Script {
    function run()
        external
        returns (SolaraPriceOracle oracle, ComponentRegistry registry, SolaraIndexProtocol protocol)
    {
        address admin = vm.envOr("ADMIN", msg.sender);
        address treasury = vm.envOr("TREASURY", msg.sender);

        vm.startBroadcast();
        oracle = new SolaraPriceOracle(admin);
        registry = new ComponentRegistry(admin, address(oracle));
        protocol = new SolaraIndexProtocol(admin, treasury, registry, oracle);
        registry.grantRole(registry.CONFIGURATOR_ROLE(), address(protocol));
        vm.stopBroadcast();
    }
}
