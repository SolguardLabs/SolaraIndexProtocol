// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { ProtocolAccess } from "../access/ProtocolAccess.sol";
import { ISolaraIndexProtocol } from "../interfaces/ISolaraIndexProtocol.sol";
import { FixedPointMath } from "../libraries/FixedPointMath.sol";
import { NavReport } from "../types/SolaraTypes.sol";

/// @title SolaraCircuitBreaker
/// @notice Optional NAV movement guard for off-chain keepers and production deployments.
contract SolaraCircuitBreaker is ProtocolAccess {
    uint256 public constant BPS = 10_000;

    struct GuardConfig {
        bool enabled;
        bool tripped;
        uint16 maxNavMoveBps;
        uint16 maxPpsMoveBps;
        uint40 minObservationDelay;
        uint40 cooldown;
    }

    struct Observation {
        uint256 nav;
        uint256 pricePerShare;
        uint40 observedAt;
        bytes32 componentHash;
    }

    mapping(address protocol => GuardConfig config) private _configs;
    mapping(address protocol => Observation observation) private _lastObservation;

    error InvalidProtocol(address protocol);
    error InvalidGuardConfiguration();
    error CircuitBreakerTripped(address protocol);
    error ObservationTooSoon(uint256 nextAllowedAt);
    error NavMoveExceeded(uint256 previousNav, uint256 nextNav, uint256 maxMoveBps);
    error PpsMoveExceeded(uint256 previousPps, uint256 nextPps, uint256 maxMoveBps);
    error ComponentHashChanged(bytes32 previousHash, bytes32 nextHash);
    error NumericOverflow(uint256 value);

    event GuardConfigured(
        address indexed protocol,
        bool enabled,
        uint16 maxNavMoveBps,
        uint16 maxPpsMoveBps,
        uint40 minObservationDelay,
        uint40 cooldown
    );
    event ObservationRecorded(
        address indexed protocol,
        uint256 nav,
        uint256 pricePerShare,
        uint40 observedAt,
        bytes32 componentHash
    );
    event CircuitBreakerStatusUpdated(address indexed protocol, bool tripped);

    constructor(
        address initialAdmin
    ) ProtocolAccess(initialAdmin) { }

    function configureGuard(
        address protocol,
        bool enabled,
        uint16 maxNavMoveBps,
        uint16 maxPpsMoveBps,
        uint40 minObservationDelay,
        uint40 cooldown
    ) external onlyRole(CONFIGURATOR_ROLE) {
        if (protocol == address(0) || protocol.code.length == 0) revert InvalidProtocol(protocol);
        if (
            maxNavMoveBps > BPS || maxPpsMoveBps > BPS
                || (enabled && (maxNavMoveBps == 0 || maxPpsMoveBps == 0))
        ) revert InvalidGuardConfiguration();

        GuardConfig storage config = _configs[protocol];
        config.enabled = enabled;
        config.maxNavMoveBps = maxNavMoveBps;
        config.maxPpsMoveBps = maxPpsMoveBps;
        config.minObservationDelay = minObservationDelay;
        config.cooldown = cooldown;

        emit GuardConfigured(
            protocol, enabled, maxNavMoveBps, maxPpsMoveBps, minObservationDelay, cooldown
        );
    }

    function checkAndRecord(
        address protocol
    ) external onlyRole(GUARDIAN_ROLE) returns (NavReport memory report) {
        GuardConfig storage config = _configs[protocol];
        if (config.tripped) revert CircuitBreakerTripped(protocol);
        report = ISolaraIndexProtocol(protocol).navReport();

        Observation memory previous = _lastObservation[protocol];
        if (config.enabled && previous.observedAt != 0) {
            _validateObservationDelay(config, previous);
            _validateNavMove(config, previous, report);
            _validatePpsMove(config, previous, report);
            if (previous.componentHash != report.componentHash) {
                revert ComponentHashChanged(previous.componentHash, report.componentHash);
            }
        }

        _lastObservation[protocol] = Observation({
            nav: report.totalValue,
            pricePerShare: report.pricePerShare,
            observedAt: _toUint40(block.timestamp),
            componentHash: report.componentHash
        });

        emit ObservationRecorded(
            protocol,
            report.totalValue,
            report.pricePerShare,
            _toUint40(block.timestamp),
            report.componentHash
        );
    }

    function trip(
        address protocol
    ) external onlyRole(GUARDIAN_ROLE) {
        _configs[protocol].tripped = true;
        emit CircuitBreakerStatusUpdated(protocol, true);
    }

    function clearTrip(
        address protocol
    ) external onlyRole(GUARDIAN_ROLE) {
        GuardConfig storage config = _configs[protocol];
        Observation memory previous = _lastObservation[protocol];
        if (previous.observedAt != 0 && config.cooldown != 0) {
            uint256 nextAllowedAt = uint256(previous.observedAt) + config.cooldown;
            if (block.timestamp < nextAllowedAt) revert ObservationTooSoon(nextAllowedAt);
        }
        config.tripped = false;
        emit CircuitBreakerStatusUpdated(protocol, false);
    }

    function forceObservation(
        address protocol
    ) external onlyRole(DEFAULT_ADMIN_ROLE) returns (NavReport memory report) {
        if (protocol == address(0) || protocol.code.length == 0) revert InvalidProtocol(protocol);
        report = ISolaraIndexProtocol(protocol).navReport();
        _lastObservation[protocol] = Observation({
            nav: report.totalValue,
            pricePerShare: report.pricePerShare,
            observedAt: _toUint40(block.timestamp),
            componentHash: report.componentHash
        });
        emit ObservationRecorded(
            protocol,
            report.totalValue,
            report.pricePerShare,
            _toUint40(block.timestamp),
            report.componentHash
        );
    }

    function guardConfig(
        address protocol
    ) external view returns (GuardConfig memory) {
        return _configs[protocol];
    }

    function lastObservation(
        address protocol
    ) external view returns (Observation memory) {
        return _lastObservation[protocol];
    }

    function wouldTrip(
        address protocol
    ) external view returns (bool tripped, bytes32 reason) {
        GuardConfig memory config = _configs[protocol];
        if (!config.enabled || config.tripped) return (config.tripped, "DISABLED_OR_TRIPPED");
        Observation memory previous = _lastObservation[protocol];
        if (previous.observedAt == 0) return (false, "NO_OBSERVATION");

        NavReport memory report = ISolaraIndexProtocol(protocol).navReport();
        if (previous.componentHash != report.componentHash) return (true, "COMPONENT_HASH");
        if (_moveBps(previous.nav, report.totalValue) > config.maxNavMoveBps) {
            return (true, "NAV_MOVE");
        }
        if (_moveBps(previous.pricePerShare, report.pricePerShare) > config.maxPpsMoveBps) {
            return (true, "PPS_MOVE");
        }
        return (false, "OK");
    }

    function _validateObservationDelay(
        GuardConfig memory config,
        Observation memory previous
    ) internal view {
        uint256 nextAllowedAt = uint256(previous.observedAt) + config.minObservationDelay;
        if (block.timestamp < nextAllowedAt) revert ObservationTooSoon(nextAllowedAt);
    }

    function _validateNavMove(
        GuardConfig memory config,
        Observation memory previous,
        NavReport memory report
    ) internal pure {
        uint256 moveBps = _moveBps(previous.nav, report.totalValue);
        if (moveBps > config.maxNavMoveBps) {
            revert NavMoveExceeded(previous.nav, report.totalValue, config.maxNavMoveBps);
        }
    }

    function _validatePpsMove(
        GuardConfig memory config,
        Observation memory previous,
        NavReport memory report
    ) internal pure {
        uint256 moveBps = _moveBps(previous.pricePerShare, report.pricePerShare);
        if (moveBps > config.maxPpsMoveBps) {
            revert PpsMoveExceeded(
                previous.pricePerShare, report.pricePerShare, config.maxPpsMoveBps
            );
        }
    }

    function _moveBps(
        uint256 previous,
        uint256 nextValue
    ) internal pure returns (uint256) {
        if (previous == 0 && nextValue == 0) return 0;
        if (previous == 0) return BPS;
        return FixedPointMath.mulDiv(FixedPointMath.absDiff(previous, nextValue), BPS, previous);
    }

    function _toUint40(
        uint256 value
    ) internal pure returns (uint40) {
        if (value > type(uint40).max) revert NumericOverflow(value);
        return uint40(value);
    }
}
