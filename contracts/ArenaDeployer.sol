// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./ArenaMarket.sol";

/**
 * @title ArenaDeployer
 * @notice Deploys ArenaMarket instances on behalf of the factory.
 *         Separated to keep factory bytecode under the 24KB contract size limit.
 */
contract ArenaDeployer {
    function deploy(
        uint256 _marketId,
        address _creator,
        address _resolver,
        address _factory,
        string calldata _question,
        string[] calldata _options,
        uint256 _endTime,
        uint256 _protocolFeeBps,
        address _feeRecipient,
        string calldata _categories,
        bool _agentOnly,
        uint256 _virtualLiquidity,
        uint256 _maxWalletBaseBps
    ) external payable returns (address) {
        ArenaMarket market = new ArenaMarket{value: msg.value}(
            _marketId, _creator, _resolver, _factory,
            _question, _options, _endTime,
            _protocolFeeBps, _feeRecipient, _categories,
            _agentOnly, _virtualLiquidity, _maxWalletBaseBps
        );
        return address(market);
    }
}
