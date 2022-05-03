// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IStrategy {
    // Total want tokens managed by strategy
    function wantLockedTotal() external view returns (uint256);

    // Main want token compounding function
    function earn() external;

    // Transfer want tokens MasterChefV2 -> strategy
    function deposit(uint256 _wantAmt)
    external
    returns (uint256);

    // Transfer want tokens strategy -> MasterChefV2
    function withdraw(uint256 _wantAmt)
    external
    returns (uint256);

    function inCaseTokensGetStuck(
        address _token,
        uint256 _amount,
        address _to
    ) external;
}