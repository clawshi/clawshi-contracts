// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./ParimutuelMarket.sol";

/**
 * @title ParimutuelDeployer
 * @notice Deploys ParimutuelMarket instances on behalf of the factory.
 *         Separated to keep factory bytecode under the 24KB contract size limit.
 */
contract ParimutuelDeployer {
    function deploy(
        uint256 _marketId, address _creator, address _resolver,
        string calldata _question, string[] calldata _options,
        uint256 _endTime, uint256 _resolutionTime,
        uint256 _protocolFeeBps, address _feeRecipient,
        string calldata _categories, bool _isPrivate
    ) external returns (address) {
        ParimutuelMarket market = new ParimutuelMarket(
            _marketId, _creator, _resolver,
            _question, _options, _endTime, _resolutionTime,
            _protocolFeeBps, _feeRecipient, _categories, _isPrivate
        );
        return address(market);
    }
}
