// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title SafeTransferLib
/// @notice Handles ERC-20 tokens that either return a boolean or return no data.
library SafeTransferLib {
    error TransferFailed(address token, address to, uint256 amount);
    error TransferFromFailed(address token, address from, address to, uint256 amount);
    error ApprovalFailed(address token, address spender, uint256 amount);

    function safeTransfer(
        address token,
        address to,
        uint256 amount
    ) internal {
        bool success;
        assembly {
            let freeMemoryPointer := mload(0x40)
            mstore(
                freeMemoryPointer,
                0xa9059cbb00000000000000000000000000000000000000000000000000000000
            )
            mstore(add(freeMemoryPointer, 4), to)
            mstore(add(freeMemoryPointer, 36), amount)
            success := call(gas(), token, 0, freeMemoryPointer, 68, 0, 32)
            if and(success, returndatasize()) {
                success := and(eq(returndatasize(), 32), eq(mload(0), 1))
            }
        }
        if (!success) revert TransferFailed(token, to, amount);
    }

    function safeTransferFrom(
        address token,
        address from,
        address to,
        uint256 amount
    ) internal {
        bool success;
        assembly {
            let freeMemoryPointer := mload(0x40)
            mstore(
                freeMemoryPointer,
                0x23b872dd00000000000000000000000000000000000000000000000000000000
            )
            mstore(add(freeMemoryPointer, 4), from)
            mstore(add(freeMemoryPointer, 36), to)
            mstore(add(freeMemoryPointer, 68), amount)
            success := call(gas(), token, 0, freeMemoryPointer, 100, 0, 32)
            if and(success, returndatasize()) {
                success := and(eq(returndatasize(), 32), eq(mload(0), 1))
            }
        }
        if (!success) revert TransferFromFailed(token, from, to, amount);
    }

    function safeApprove(
        address token,
        address spender,
        uint256 amount
    ) internal {
        bool success;
        assembly {
            let freeMemoryPointer := mload(0x40)
            mstore(
                freeMemoryPointer,
                0x095ea7b300000000000000000000000000000000000000000000000000000000
            )
            mstore(add(freeMemoryPointer, 4), spender)
            mstore(add(freeMemoryPointer, 36), amount)
            success := call(gas(), token, 0, freeMemoryPointer, 68, 0, 32)
            if and(success, returndatasize()) {
                success := and(eq(returndatasize(), 32), eq(mload(0), 1))
            }
        }
        if (!success) revert ApprovalFailed(token, spender, amount);
    }
}
