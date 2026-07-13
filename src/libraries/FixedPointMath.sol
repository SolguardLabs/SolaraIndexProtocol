// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title FixedPointMath
/// @notice Common full precision and fixed point helpers.
library FixedPointMath {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    error DivisionByZero();
    error MulDivOverflow();
    error PercentageTooLarge(uint256 value);

    function mulWadDown(
        uint256 x,
        uint256 y
    ) internal pure returns (uint256) {
        return mulDiv(x, y, WAD);
    }

    function mulWadUp(
        uint256 x,
        uint256 y
    ) internal pure returns (uint256) {
        return mulDivUp(x, y, WAD);
    }

    function divWadDown(
        uint256 x,
        uint256 y
    ) internal pure returns (uint256) {
        return mulDiv(x, WAD, y);
    }

    function divWadUp(
        uint256 x,
        uint256 y
    ) internal pure returns (uint256) {
        return mulDivUp(x, WAD, y);
    }

    function percentOf(
        uint256 amount,
        uint256 bps
    ) internal pure returns (uint256) {
        if (bps > BPS) revert PercentageTooLarge(bps);
        return mulDiv(amount, bps, BPS);
    }

    function percentOfUp(
        uint256 amount,
        uint256 bps
    ) internal pure returns (uint256) {
        if (bps > BPS) revert PercentageTooLarge(bps);
        return mulDivUp(amount, bps, BPS);
    }

    function ceilDiv(
        uint256 x,
        uint256 y
    ) internal pure returns (uint256) {
        if (y == 0) revert DivisionByZero();
        return x == 0 ? 0 : (x - 1) / y + 1;
    }

    function min(
        uint256 x,
        uint256 y
    ) internal pure returns (uint256) {
        return x < y ? x : y;
    }

    function max(
        uint256 x,
        uint256 y
    ) internal pure returns (uint256) {
        return x > y ? x : y;
    }

    function absDiff(
        uint256 x,
        uint256 y
    ) internal pure returns (uint256) {
        return x > y ? x - y : y - x;
    }

    function mulDivUp(
        uint256 x,
        uint256 y,
        uint256 denominator
    ) internal pure returns (uint256 z) {
        z = mulDiv(x, y, denominator);
        if (mulmod(x, y, denominator) != 0) z += 1;
    }

    function mulDiv(
        uint256 x,
        uint256 y,
        uint256 denominator
    ) internal pure returns (uint256 result) {
        if (denominator == 0) revert DivisionByZero();

        uint256 prod0;
        uint256 prod1;
        assembly {
            let mm := mulmod(x, y, not(0))
            prod0 := mul(x, y)
            prod1 := sub(sub(mm, prod0), lt(mm, prod0))
        }

        if (prod1 == 0) {
            return prod0 / denominator;
        }

        if (denominator <= prod1) revert MulDivOverflow();

        uint256 remainder;
        assembly {
            remainder := mulmod(x, y, denominator)
            prod1 := sub(prod1, gt(remainder, prod0))
            prod0 := sub(prod0, remainder)
        }

        uint256 twos = denominator & (~denominator + 1);
        assembly {
            denominator := div(denominator, twos)
            prod0 := div(prod0, twos)
            twos := add(div(sub(0, twos), twos), 1)
        }
        prod0 |= prod1 * twos;

        uint256 inverse = (3 * denominator) ^ 2;
        inverse *= 2 - denominator * inverse;
        inverse *= 2 - denominator * inverse;
        inverse *= 2 - denominator * inverse;
        inverse *= 2 - denominator * inverse;
        inverse *= 2 - denominator * inverse;
        inverse *= 2 - denominator * inverse;

        result = prod0 * inverse;
    }

    function sqrt(
        uint256 x
    ) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        uint256 y = x;
        z = 1;
        if (y >= 2 ** 128) {
            y >>= 128;
            z <<= 64;
        }
        if (y >= 2 ** 64) {
            y >>= 64;
            z <<= 32;
        }
        if (y >= 2 ** 32) {
            y >>= 32;
            z <<= 16;
        }
        if (y >= 2 ** 16) {
            y >>= 16;
            z <<= 8;
        }
        if (y >= 2 ** 8) {
            y >>= 8;
            z <<= 4;
        }
        if (y >= 2 ** 4) {
            y >>= 4;
            z <<= 2;
        }
        if (y >= 2 ** 2) z <<= 1;

        for (uint256 i = 0; i < 7; ++i) {
            z = (z + x / z) >> 1;
        }
        uint256 roundedDown = x / z;
        return z < roundedDown ? z : roundedDown;
    }
}
