// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IClawshiFactory — Interface for factory agent registration checks
interface IClawshiFactory {
    function isAgent(address _addr) external view returns (bool);
    function owner() external view returns (address);
}
