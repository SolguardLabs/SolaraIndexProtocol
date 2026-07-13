// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { ProtocolAccess } from "../access/ProtocolAccess.sol";
import { IERC20 } from "../interfaces/IERC20.sol";
import { FixedPointMath } from "../libraries/FixedPointMath.sol";
import { IndexMath } from "../libraries/IndexMath.sol";
import { WeightMath } from "../libraries/WeightMath.sol";
import {
    Component,
    ComponentConfig,
    ComponentReport,
    ComponentStatus
} from "../types/SolaraTypes.sol";

interface ISolaraOracleLike {
    function getPrice(
        address asset
    ) external view returns (uint256);
}

/// @title ComponentRegistry
/// @notice Stores component metadata, active weights and target weights.
contract ComponentRegistry is ProtocolAccess {
    using FixedPointMath for uint256;

    uint256 public constant BPS = 10_000;

    mapping(address asset => Component component) private _components;
    address[] private _componentList;

    address public oracle;

    error InvalidComponent(address asset);
    error ComponentAlreadyListed(address asset);
    error ComponentNotListed(address asset);
    error ComponentNotActive(address asset);
    error ComponentStillActive(address asset);
    error InvalidComponentSet();
    error InvalidBalanceBounds(uint256 minBalance, uint256 maxBalance);
    error NumericOverflow(uint256 value);

    event ComponentListed(address indexed asset, bytes32 indexed id, uint16 weightBps);
    event ComponentStatusUpdated(address indexed asset, ComponentStatus status);
    event ComponentBoundsUpdated(address indexed asset, uint128 minBalance, uint128 maxBalance);
    event ComponentRiskUpdated(
        address indexed asset, uint16 minWeightBps, uint16 maxWeightBps, uint16 maxDeviationBps
    );
    event ComponentWeightUpdated(
        address indexed asset, uint16 previousWeightBps, uint16 newWeightBps
    );
    event ComponentTargetUpdated(
        address indexed asset, uint16 previousTargetBps, uint16 newTargetBps
    );
    event OracleUpdated(address indexed previousOracle, address indexed newOracle);

    constructor(
        address initialAdmin,
        address initialOracle
    ) ProtocolAccess(initialAdmin) {
        if (initialOracle == address(0) || initialOracle.code.length == 0) {
            revert InvalidComponent(initialOracle);
        }
        oracle = initialOracle;
        emit OracleUpdated(address(0), initialOracle);
    }

    function setOracle(
        address newOracle
    ) external onlyRole(CONFIGURATOR_ROLE) {
        if (newOracle == address(0) || newOracle.code.length == 0) {
            revert InvalidComponent(newOracle);
        }
        address previous = oracle;
        oracle = newOracle;
        emit OracleUpdated(previous, newOracle);
    }

    function listComponents(
        ComponentConfig[] calldata configs
    ) external onlyRole(CONFIGURATOR_ROLE) {
        if (configs.length == 0) revert InvalidComponentSet();

        uint256 existingActiveWeight = _activeWeightSum();
        uint256 addedWeight;
        for (uint256 i = 0; i < configs.length; ++i) {
            ComponentConfig calldata config = configs[i];
            _validateNewComponent(config);
            addedWeight += config.weightBps;
        }
        if (existingActiveWeight + addedWeight != BPS) {
            revert WeightMath.WeightSumMismatch(existingActiveWeight + addedWeight);
        }

        for (uint256 i = 0; i < configs.length; ++i) {
            _listComponent(configs[i]);
        }
    }

    function setComponentStatus(
        address asset,
        ComponentStatus status
    ) external onlyRole(GUARDIAN_ROLE) {
        Component storage component = _requireComponent(asset);
        if (status == ComponentStatus.Unlisted) revert InvalidComponent(asset);
        component.status = status;
        component.updatedAt = _toUint40(block.timestamp);
        emit ComponentStatusUpdated(asset, status);
    }

    function setBalanceBounds(
        address asset,
        uint128 minBalance,
        uint128 maxBalance
    ) external onlyRole(CONFIGURATOR_ROLE) {
        if (maxBalance != 0 && minBalance > maxBalance) {
            revert InvalidBalanceBounds(minBalance, maxBalance);
        }
        Component storage component = _requireComponent(asset);
        component.minBalance = minBalance;
        component.maxBalance = maxBalance;
        component.updatedAt = _toUint40(block.timestamp);
        emit ComponentBoundsUpdated(asset, minBalance, maxBalance);
    }

    function setRiskBounds(
        address asset,
        uint16 minWeightBps,
        uint16 maxWeightBps,
        uint16 maxDeviationBps
    ) external onlyRole(CONFIGURATOR_ROLE) {
        Component storage component = _requireComponent(asset);
        WeightMath.validateWeightRange(asset, component.weightBps, minWeightBps, maxWeightBps);
        component.minWeightBps = minWeightBps;
        component.maxWeightBps = maxWeightBps;
        component.maxDeviationBps = maxDeviationBps;
        component.updatedAt = _toUint40(block.timestamp);
        emit ComponentRiskUpdated(asset, minWeightBps, maxWeightBps, maxDeviationBps);
    }

    function setTargetWeights(
        address[] calldata assets,
        uint16[] calldata weights
    ) external onlyRole(CONFIGURATOR_ROLE) {
        WeightMath.validateWeights(assets, weights);
        for (uint256 i = 0; i < assets.length; ++i) {
            Component storage component = _requireActiveComponent(assets[i]);
            WeightMath.validateWeightRange(
                assets[i], weights[i], component.minWeightBps, component.maxWeightBps
            );
        }
        for (uint256 i = 0; i < assets.length; ++i) {
            Component storage component = _components[assets[i]];
            uint16 previous = component.targetWeightBps;
            component.targetWeightBps = weights[i];
            component.updatedAt = _toUint40(block.timestamp);
            emit ComponentTargetUpdated(assets[i], previous, weights[i]);
        }
    }

    function applyTargetWeights(
        address[] calldata assets,
        uint16[] calldata weights
    ) external onlyRole(CONFIGURATOR_ROLE) {
        WeightMath.validateWeights(assets, weights);
        for (uint256 i = 0; i < assets.length; ++i) {
            Component storage component = _requireActiveComponent(assets[i]);
            WeightMath.validateWeightRange(
                assets[i], weights[i], component.minWeightBps, component.maxWeightBps
            );
        }
        for (uint256 i = 0; i < assets.length; ++i) {
            Component storage component = _components[assets[i]];
            uint16 previous = component.weightBps;
            component.weightBps = weights[i];
            component.targetWeightBps = weights[i];
            component.updatedAt = _toUint40(block.timestamp);
            emit ComponentWeightUpdated(assets[i], previous, weights[i]);
        }
    }

    function componentCount() external view returns (uint256) {
        return _componentList.length;
    }

    function componentAt(
        uint256 index
    ) external view returns (address) {
        return _componentList[index];
    }

    function activeComponents() external view returns (address[] memory assets) {
        uint256 count;
        for (uint256 i = 0; i < _componentList.length; ++i) {
            if (_components[_componentList[i]].status == ComponentStatus.Active) count++;
        }
        assets = new address[](count);
        uint256 cursor;
        for (uint256 i = 0; i < _componentList.length; ++i) {
            address asset = _componentList[i];
            if (_components[asset].status == ComponentStatus.Active) {
                assets[cursor++] = asset;
            }
        }
    }

    function getComponent(
        address asset
    ) external view returns (Component memory) {
        return _requireComponentView(asset);
    }

    function getComponents(
        address[] calldata assets
    ) external view returns (Component[] memory components) {
        components = new Component[](assets.length);
        for (uint256 i = 0; i < assets.length; ++i) {
            components[i] = _requireComponentView(assets[i]);
        }
    }

    function weightOf(
        address asset
    ) external view returns (uint16) {
        return _requireComponentView(asset).weightBps;
    }

    function targetWeightOf(
        address asset
    ) external view returns (uint16) {
        return _requireComponentView(asset).targetWeightBps;
    }

    function isActive(
        address asset
    ) external view returns (bool) {
        return _components[asset].status == ComponentStatus.Active;
    }

    function componentHash() external view returns (bytes32) {
        return _componentHash();
    }

    function componentReports(
        address holder
    ) external view returns (ComponentReport[] memory reports) {
        reports = new ComponentReport[](_componentList.length);
        uint256 totalValue = _portfolioValue(holder);
        for (uint256 i = 0; i < _componentList.length; ++i) {
            address asset = _componentList[i];
            Component memory component = _components[asset];
            uint256 balance = IERC20(asset).balanceOf(holder);
            uint256 price = ISolaraOracleLike(oracle).getPrice(asset);
            uint256 value = IndexMath.valueOf(balance, component.decimals, price);
            reports[i] = ComponentReport({
                asset: asset,
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
                value: value,
                currentWeightBps: WeightMath.currentWeightBps(value, totalValue)
            });
        }
    }

    function validateActiveWeights() external view returns (bool) {
        return _activeWeightSum() == BPS;
    }

    function _listComponent(
        ComponentConfig calldata config
    ) internal {
        Component storage component = _components[config.asset];
        component.asset = config.asset;
        component.id = config.id;
        component.status = ComponentStatus.Active;
        component.decimals = config.decimals;
        component.weightBps = config.weightBps;
        component.targetWeightBps = config.weightBps;
        component.minWeightBps = config.minWeightBps;
        component.maxWeightBps = config.maxWeightBps;
        component.maxDeviationBps = config.maxDeviationBps;
        component.listedAt = _toUint40(block.timestamp);
        component.updatedAt = _toUint40(block.timestamp);
        component.minBalance = config.minBalance;
        component.maxBalance = config.maxBalance;
        _componentList.push(config.asset);
        emit ComponentListed(config.asset, config.id, config.weightBps);
    }

    function _validateNewComponent(
        ComponentConfig calldata config
    ) internal view {
        if (config.asset == address(0) || config.asset.code.length == 0) {
            revert InvalidComponent(config.asset);
        }
        if (_components[config.asset].asset != address(0)) {
            revert ComponentAlreadyListed(config.asset);
        }
        if (config.id == bytes32(0) || config.decimals > 36) revert InvalidComponent(config.asset);
        if (config.maxBalance != 0 && config.minBalance > config.maxBalance) {
            revert InvalidBalanceBounds(config.minBalance, config.maxBalance);
        }
        WeightMath.validateWeightRange(
            config.asset, config.weightBps, config.minWeightBps, config.maxWeightBps
        );
    }

    function _requireComponent(
        address asset
    ) internal view returns (Component storage component) {
        component = _components[asset];
        if (component.asset == address(0)) revert ComponentNotListed(asset);
    }

    function _requireActiveComponent(
        address asset
    ) internal view returns (Component storage component) {
        component = _requireComponent(asset);
        if (component.status != ComponentStatus.Active) revert ComponentNotActive(asset);
    }

    function _requireComponentView(
        address asset
    ) internal view returns (Component storage component) {
        component = _components[asset];
        if (component.asset == address(0)) revert ComponentNotListed(asset);
    }

    function _activeWeightSum() internal view returns (uint256 sum) {
        for (uint256 i = 0; i < _componentList.length; ++i) {
            Component storage component = _components[_componentList[i]];
            if (component.status == ComponentStatus.Active) sum += component.weightBps;
        }
    }

    function _portfolioValue(
        address holder
    ) internal view returns (uint256 totalValue) {
        for (uint256 i = 0; i < _componentList.length; ++i) {
            address asset = _componentList[i];
            Component storage component = _components[asset];
            if (component.status != ComponentStatus.Active) continue;
            uint256 balance = IERC20(asset).balanceOf(holder);
            uint256 price = ISolaraOracleLike(oracle).getPrice(asset);
            totalValue += IndexMath.valueOf(balance, component.decimals, price);
        }
    }

    function _componentHash() internal view returns (bytes32 hash) {
        bytes32 rolling = keccak256("SOLARA_COMPONENTS_V1");
        for (uint256 i = 0; i < _componentList.length; ++i) {
            Component storage component = _components[_componentList[i]];
            rolling = keccak256(
                abi.encode(
                    rolling,
                    component.asset,
                    component.id,
                    component.status,
                    component.weightBps,
                    component.targetWeightBps,
                    component.minWeightBps,
                    component.maxWeightBps
                )
            );
        }
        return rolling;
    }

    function _toUint40(
        uint256 value
    ) internal pure returns (uint40) {
        if (value > type(uint40).max) revert NumericOverflow(value);
        return uint40(value);
    }
}
