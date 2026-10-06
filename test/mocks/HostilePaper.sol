// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Adversarial code substituted only in tests; not the launch token.
contract HostilePaper is ERC20 {
    address public target;
    bytes public payload;
    bool public armed;
    bool public reentrySucceeded;
    bytes4 public reentryError;
    bool public shortTransfer;
    bool public falseReturn;

    constructor() ERC20("Hostile", "HST") {}

    function configure(address target_, bytes calldata payload_, bool short_, bool false_) external {
        target = target_;
        payload = payload_;
        armed = payload_.length != 0;
        shortTransfer = short_;
        falseReturn = false_;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (falseReturn) return false;
        return super.transferFrom(from, to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (shortTransfer && value != 0) {
            super._update(from, to, value - 1);
            super._update(from, address(0), 1);
        } else {
            super._update(from, to, value);
        }
        if (armed) {
            armed = false;
            (bool ok, bytes memory result) = target.call(payload);
            reentrySucceeded = ok;
            if (result.length >= 4) reentryError = bytes4(result);
        }
    }
}
