// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { IERC20 } from "../interfaces/IERC20.sol";

/// @title SolaraIndexToken
/// @notice ERC-20 receipt token minted and burned exclusively by the index protocol.
contract SolaraIndexToken is IERC20 {
    string public override name;
    string public override symbol;
    uint8 public immutable override decimals = 18;
    uint256 public override totalSupply;

    address public manager;
    address public pendingManager;

    mapping(address account => uint256) public override balanceOf;
    mapping(address owner => mapping(address spender => uint256)) public override allowance;

    error ZeroAddress();
    error InsufficientBalance(address account, uint256 balance, uint256 amount);
    error InsufficientAllowance(address owner, address spender, uint256 allowance, uint256 amount);
    error UnauthorizedManager(address caller, address manager);
    error PendingManagerMismatch(address caller, address pendingManager);

    event ManagerTransferStarted(address indexed previousManager, address indexed pendingManager);
    event ManagerTransferred(address indexed previousManager, address indexed newManager);

    modifier onlyManager() {
        if (msg.sender != manager) revert UnauthorizedManager(msg.sender, manager);
        _;
    }

    constructor(
        string memory tokenName,
        string memory tokenSymbol,
        address initialManager
    ) {
        if (initialManager == address(0)) revert ZeroAddress();
        name = tokenName;
        symbol = tokenSymbol;
        manager = initialManager;
        emit ManagerTransferred(address(0), initialManager);
    }

    function approve(
        address spender,
        uint256 amount
    ) external override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transfer(
        address to,
        uint256 amount
    ) external override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external override returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance(from, msg.sender, allowed, amount);
            allowance[from][msg.sender] = allowed - amount;
            emit Approval(from, msg.sender, allowed - amount);
        }
        _transfer(from, to, amount);
        return true;
    }

    function increaseAllowance(
        address spender,
        uint256 addedValue
    ) external returns (bool) {
        _approve(msg.sender, spender, allowance[msg.sender][spender] + addedValue);
        return true;
    }

    function decreaseAllowance(
        address spender,
        uint256 subtractedValue
    ) external returns (bool) {
        uint256 currentAllowance = allowance[msg.sender][spender];
        if (currentAllowance < subtractedValue) {
            revert InsufficientAllowance(msg.sender, spender, currentAllowance, subtractedValue);
        }
        _approve(msg.sender, spender, currentAllowance - subtractedValue);
        return true;
    }

    function mint(
        address account,
        uint256 amount
    ) external onlyManager {
        if (account == address(0)) revert ZeroAddress();
        totalSupply += amount;
        balanceOf[account] += amount;
        emit Transfer(address(0), account, amount);
    }

    function burn(
        address account,
        uint256 amount
    ) external onlyManager {
        _burn(account, amount);
    }

    function burnFrom(
        address account,
        uint256 amount
    ) external onlyManager {
        _burn(account, amount);
    }

    function startManagerTransfer(
        address newManager
    ) external onlyManager {
        if (newManager == address(0)) revert ZeroAddress();
        pendingManager = newManager;
        emit ManagerTransferStarted(manager, newManager);
    }

    function acceptManagerTransfer() external {
        if (msg.sender != pendingManager) {
            revert PendingManagerMismatch(msg.sender, pendingManager);
        }
        address previous = manager;
        manager = msg.sender;
        pendingManager = address(0);
        emit ManagerTransferred(previous, msg.sender);
    }

    function cancelManagerTransfer() external onlyManager {
        pendingManager = address(0);
        emit ManagerTransferStarted(manager, address(0));
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal {
        if (to == address(0) || from == address(0)) revert ZeroAddress();
        uint256 balance = balanceOf[from];
        if (balance < amount) revert InsufficientBalance(from, balance, amount);
        unchecked {
            balanceOf[from] = balance - amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }

    function _burn(
        address account,
        uint256 amount
    ) internal {
        if (account == address(0)) revert ZeroAddress();
        uint256 balance = balanceOf[account];
        if (balance < amount) revert InsufficientBalance(account, balance, amount);
        unchecked {
            balanceOf[account] = balance - amount;
            totalSupply -= amount;
        }
        emit Transfer(account, address(0), amount);
    }

    function _approve(
        address owner,
        address spender,
        uint256 amount
    ) internal {
        if (owner == address(0) || spender == address(0)) revert ZeroAddress();
        allowance[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }
}
