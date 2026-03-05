// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./CTFMarket.sol";

/**
 * @title CTFDeployer
 * @notice Deploys CTFMarket instances on behalf of the factory.
 *         Separated to keep factory bytecode under the 24KB contract size limit.
 */
contract CTFDeployer {
    function deploy(
        uint256 _marketId, address _creator, address _resolver,
        string calldata _question, uint256 _endTime, uint256 _resolutionTime,
        uint256 _protocolFeeBps, address _feeRecipient,
        string calldata _categories, uint256 _virtualLiquidity,
        bool _isPrivate, uint256 _lpFeeBps
    ) external returns (address) {
        CTFMarket market = new CTFMarket(
            _marketId, _creator, _resolver,
            _question, _endTime, _resolutionTime,
            _protocolFeeBps, _feeRecipient, _categories,
            _virtualLiquidity, _isPrivate, _lpFeeBps
        );
        return address(market);
    }
}
