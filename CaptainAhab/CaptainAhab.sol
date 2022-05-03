// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.0;

import "./libs/ERC20.sol";

// Revolution Token
contract RevolutionToken is ERC20('Revolution', 'REV') {

    constructor() {
        _mint(address(msg.sender), uint256(37500 ether));
    }

    /// @notice Creates `_amount` token to `_to`. Must only be called by the owner (MasterChef).
    function mint(address _to, uint256 _amount) external onlyOwner {
        _mint(_to, _amount);
    }
}