// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IVotingOracle — Interface for the decentralized voting oracle contract
interface IVotingOracle {
    function depositVoterReward(uint256 _marketId) external payable;
    function notifyMarketEnded(uint256 _marketId) external;

    /// @notice Returns true if emergency resolve conditions are met:
    ///         (a) Assertion was disputed and UMA DVM hasn't returned in 3 days, OR
    ///         (b) UMA DVM returned INVALID (assertion rejected — question unanswerable)
    function canEmergencyResolve(uint256 _marketId) external view returns (bool);
}
