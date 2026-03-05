// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./CLOBMarket.sol";

/**
 * @title CLOBDeployer
 * @notice Deploys CLOBMarket instances on behalf of the factory.
 *         Uses SSTORE2 pattern with two code stores to split CLOBMarket
 *         creation code across two contracts, keeping everything under
 *         the 24KB EIP-170 limit.
 */
contract CLOBDeployer {
    /// @dev Addresses of the two SSTORE2 code stores
    address public immutable codeStore1;
    address public immutable codeStore2;
    /// @dev Length of each half
    uint256 public immutable halfLen;
    /// @dev Total creation code length
    uint256 public immutable totalLen;

    constructor() {
        bytes memory code = type(CLOBMarket).creationCode;
        totalLen = code.length;
        halfLen = code.length / 2;

        // Split into two halves
        uint256 h = halfLen;
        uint256 rem = code.length - h;

        bytes memory part1 = new bytes(h);
        bytes memory part2 = new bytes(rem);

        assembly {
            let src := add(code, 32)
            let dst1 := add(part1, 32)
            let dst2 := add(part2, 32)
            // Copy first half
            for { let i := 0 } lt(i, h) { i := add(i, 32) } {
                mstore(add(dst1, i), mload(add(src, i)))
            }
            // Copy second half
            for { let i := 0 } lt(i, rem) { i := add(i, 32) } {
                mstore(add(dst2, i), mload(add(add(src, h), i)))
            }
        }

        codeStore1 = _sstore2Write(part1);
        codeStore2 = _sstore2Write(part2);
    }

    function _sstore2Write(bytes memory data) internal returns (address result) {
        uint256 dataLen = data.length;
        uint256 runtimeLen = dataLen + 1; // 0x00 prefix + data

        // Init code: 12-byte header
        // PUSH2 runtimeLen (3) | DUP1 (1) | PUSH1 0x0c (2) | PUSH1 0 (2) | CODECOPY (1) | PUSH1 0 (2) | RETURN (1) = 12
        bytes memory initCode = new bytes(12 + 1 + dataLen);

        initCode[0] = 0x61;                    // PUSH2
        initCode[1] = bytes1(uint8(runtimeLen >> 8));
        initCode[2] = bytes1(uint8(runtimeLen));
        initCode[3] = 0x80;                    // DUP1
        initCode[4] = 0x60;                    // PUSH1
        initCode[5] = 0x0c;                    // 12
        initCode[6] = 0x60;                    // PUSH1
        initCode[7] = 0x00;                    // 0
        initCode[8] = 0x39;                    // CODECOPY
        initCode[9] = 0x60;                    // PUSH1
        initCode[10] = 0x00;                   // 0
        initCode[11] = 0xf3;                   // RETURN
        initCode[12] = 0x00;                   // STOP prefix

        // Copy data after header + STOP
        assembly {
            let src := add(data, 32)
            let dst := add(initCode, 45) // 32 (length word) + 13 (header + STOP)
            for { let i := 0 } lt(i, dataLen) { i := add(i, 32) } {
                mstore(add(dst, i), mload(add(src, i)))
            }
        }

        assembly {
            result := create(0, add(initCode, 32), mload(initCode))
        }
        require(result != address(0), "SSTORE2 write failed");
    }

    function deploy(
        uint256 _marketId, address _creator, address _resolver,
        string calldata _question, uint256 _endTime, uint256 _resolutionTime,
        uint256 _protocolFeeBps, address _feeRecipient,
        string calldata _categories,
        bool _isPrivate, uint256 _makerRebateBps, uint256 _makerRewardBps
    ) external returns (address) {
        // Read creation code from both code stores
        bytes memory creationCode = _readCode();

        // ABI-encode constructor arguments and deploy
        return _deployWithArgs(
            creationCode,
            _marketId, _creator, _resolver,
            _question, _endTime, _resolutionTime,
            _protocolFeeBps, _feeRecipient, _categories,
            _isPrivate, _makerRebateBps, _makerRewardBps
        );
    }

    function _readCode() internal view returns (bytes memory creationCode) {
        uint256 h = halfLen;
        uint256 total = totalLen;
        uint256 rem = total - h;
        creationCode = new bytes(total);
        address s1 = codeStore1;
        address s2 = codeStore2;
        assembly ("memory-safe") {
            let dst := add(creationCode, 32)
            extcodecopy(s1, dst, 1, h)
            extcodecopy(s2, add(dst, h), 1, rem)
        }
    }

    function _deployWithArgs(
        bytes memory _code,
        uint256 _marketId, address _creator, address _resolver,
        string calldata _question, uint256 _endTime, uint256 _resolutionTime,
        uint256 _protocolFeeBps, address _feeRecipient,
        string calldata _categories,
        bool _isPrivate, uint256 _makerRebateBps, uint256 _makerRewardBps
    ) internal returns (address) {
        bytes memory args = abi.encode(
            _marketId, _creator, _resolver,
            _question, _endTime, _resolutionTime,
            _protocolFeeBps, _feeRecipient, _categories,
            _isPrivate, _makerRebateBps, _makerRewardBps
        );
        bytes memory initCode = abi.encodePacked(_code, args);
        address market;
        assembly ("memory-safe") {
            market := create(0, add(initCode, 32), mload(initCode))
        }
        require(market != address(0), "Market deploy failed");
        return market;
    }
}
