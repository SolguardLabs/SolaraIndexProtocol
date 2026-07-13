// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title ProtocolAccess
/// @notice Small role based access controller tailored for the Solara lab.
contract ProtocolAccess {
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 public constant CONFIGURATOR_ROLE = keccak256("CONFIGURATOR_ROLE");
    bytes32 public constant REBALANCER_ROLE = keccak256("REBALANCER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant ORACLE_REPORTER_ROLE = keccak256("ORACLE_REPORTER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    struct RoleData {
        mapping(address account => bool) members;
        bytes32 adminRole;
    }

    mapping(bytes32 role => RoleData data) private _roles;

    error ZeroAddress();
    error MissingRole(address account, bytes32 role);
    error InvalidRoleAdmin(bytes32 role, bytes32 adminRole);

    event RoleAdminChanged(
        bytes32 indexed role, bytes32 indexed previousAdminRole, bytes32 indexed newAdminRole
    );
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);

    constructor(
        address initialAdmin
    ) {
        if (initialAdmin == address(0)) revert ZeroAddress();

        _roles[DEFAULT_ADMIN_ROLE].adminRole = DEFAULT_ADMIN_ROLE;
        _roles[CONFIGURATOR_ROLE].adminRole = DEFAULT_ADMIN_ROLE;
        _roles[REBALANCER_ROLE].adminRole = DEFAULT_ADMIN_ROLE;
        _roles[GUARDIAN_ROLE].adminRole = DEFAULT_ADMIN_ROLE;
        _roles[ORACLE_REPORTER_ROLE].adminRole = DEFAULT_ADMIN_ROLE;
        _roles[EMERGENCY_ROLE].adminRole = DEFAULT_ADMIN_ROLE;

        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(CONFIGURATOR_ROLE, initialAdmin);
        _grantRole(REBALANCER_ROLE, initialAdmin);
        _grantRole(GUARDIAN_ROLE, initialAdmin);
        _grantRole(ORACLE_REPORTER_ROLE, initialAdmin);
        _grantRole(EMERGENCY_ROLE, initialAdmin);
    }

    modifier onlyRole(
        bytes32 role
    ) {
        _checkRole(role, msg.sender);
        _;
    }

    function hasRole(
        bytes32 role,
        address account
    ) public view returns (bool) {
        return _roles[role].members[account];
    }

    function getRoleAdmin(
        bytes32 role
    ) public view returns (bytes32) {
        bytes32 admin = _roles[role].adminRole;
        return admin == bytes32(0) && role != DEFAULT_ADMIN_ROLE ? DEFAULT_ADMIN_ROLE : admin;
    }

    function grantRole(
        bytes32 role,
        address account
    ) external onlyRole(getRoleAdmin(role)) {
        if (account == address(0)) revert ZeroAddress();
        _grantRole(role, account);
    }

    function revokeRole(
        bytes32 role,
        address account
    ) external onlyRole(getRoleAdmin(role)) {
        _revokeRole(role, account);
    }

    function renounceRole(
        bytes32 role
    ) external {
        _revokeRole(role, msg.sender);
    }

    function setRoleAdmin(
        bytes32 role,
        bytes32 adminRole
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (role == DEFAULT_ADMIN_ROLE && adminRole != DEFAULT_ADMIN_ROLE) {
            revert InvalidRoleAdmin(role, adminRole);
        }
        bytes32 previous = getRoleAdmin(role);
        _roles[role].adminRole = adminRole;
        emit RoleAdminChanged(role, previous, adminRole);
    }

    function _checkRole(
        bytes32 role,
        address account
    ) internal view {
        if (!hasRole(role, account)) revert MissingRole(account, role);
    }

    function _grantRole(
        bytes32 role,
        address account
    ) internal {
        if (!_roles[role].members[account]) {
            _roles[role].members[account] = true;
            emit RoleGranted(role, account, msg.sender);
        }
    }

    function _revokeRole(
        bytes32 role,
        address account
    ) internal {
        if (_roles[role].members[account]) {
            _roles[role].members[account] = false;
            emit RoleRevoked(role, account, msg.sender);
        }
    }
}
