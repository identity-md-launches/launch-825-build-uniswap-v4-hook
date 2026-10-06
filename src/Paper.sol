// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Fixed supply; transfers to the dead address do not reduce totalSupply.
contract Paper is ERC20 {
    constructor() ERC20("paper", "paper") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}
