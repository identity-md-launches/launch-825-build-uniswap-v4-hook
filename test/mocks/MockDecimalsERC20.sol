// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockDecimalsERC20 is ERC20 {
    uint8 private immutable units;

    constructor(uint8 decimals_) ERC20("Decimals", "DEC") {
        units = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return units;
    }
}
