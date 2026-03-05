// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./MultiChoiceCTFMarket.sol";

/**
 * @title MultiChoiceMarketDeployer
 * @notice Deploys MultiChoiceCTFMarket instances on behalf of the factory.
 *         Separated to keep factory bytecode under the 24KB contract size limit.
 */
contract MultiChoiceMarketDeployer {
    function deploy(
        uint256 _marketId, address _creator, address _resolver,
        string calldata _question, string[] calldata _options,
        uint256 _endTime, uint256 _resolutionTime,
        uint256 _protocolFeeBps, address _feeRecipient,
        string calldata _categories, uint256 _virtualLiquidity,
        bool _isPrivate, uint256 _lpFeeBps
    ) external returns (address) {
        MultiChoiceCTFMarket market = new MultiChoiceCTFMarket(
            _marketId, _creator, _resolver,
            _question, _options, _endTime, _resolutionTime,
            _protocolFeeBps, _feeRecipient, _categories,
            _virtualLiquidity, _isPrivate, _lpFeeBps
        );
        return address(market);
    }
}
