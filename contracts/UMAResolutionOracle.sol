// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title UMAResolutionOracle
 * @notice Decentralized resolution for Clawshi prediction markets using UMA's
 *         Optimistic Oracle V3 (OOv3).
 *
 *  Flow:
 *    1. Market ends → anyone calls proposeOutcome() with a bond in `currency`
 *    2. 2-hour liveness window — anyone can dispute by calling disputeAssertion()
 *    3. If NO dispute: settleAndResolve() finalizes, proposer gets bond back + fee
 *    4. If DISPUTED: escalates to UMA DVM for arbitration
 *       → Winner gets 1.5x bond, UMA Store gets 0.5x loser's bond
 *
 *  Bond currency: Configurable ERC20 (TestnetERC20 on testnet, WETH on mainnet)
 *  If currency == WETH, contract auto-wraps ETH sent with propose/dispute calls.
 *  Otherwise, caller must approve the currency token to this contract first.
 *
 *  Supports: BINARY, MULTI, PARIMUTUEL, CLOB, ARENA market types
 */

import "./IClawshiFactory.sol";

// ── UMA OOv3 Interface ──
interface IOptimisticOracleV3 {
    struct EscalationManagerSettings {
        bool arbitrateViaEscalationManager;
        bool discardOracle;
        bool validateDisputers;
        address assertingCaller;
        address escalationManager;
    }

    struct Assertion {
        EscalationManagerSettings escalationManagerSettings;
        address asserter;
        uint64 assertionTime;
        bool settled;
        address currency;
        uint64 expirationTime;
        bool settlementResolution;
        bytes32 domainId;
        bytes32 identifier;
        uint256 bond;
        address callbackRecipient;
        address disputer;
    }

    function assertTruth(
        bytes calldata claim,
        address asserter,
        address callbackRecipient,
        address escalationManager,
        uint64 liveness,
        address currency,
        uint256 bond,
        bytes32 defaultIdentifier,
        bytes32 domainId
    ) external returns (bytes32 assertionId);

    function settleAssertion(bytes32 assertionId) external;
    function settleAndGetAssertionResult(bytes32 assertionId) external returns (bool);
    function getAssertion(bytes32 assertionId) external view returns (Assertion memory);
    function getMinimumBond(address currency) external view returns (uint256);
    function defaultIdentifier() external view returns (bytes32);

    function disputeAssertion(bytes32 assertionId, address disputer) external;
}

// ── ERC20 / WETH Interface ──
interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}

interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
}

// ── Market resolve interfaces ──
interface IResolvableBinary {
    function resolve(uint8 _outcome) external;
}

interface IResolvableMulti {
    function resolve(uint256 _winOption, bool _invalid) external;
}

interface IResolvablePari {
    function resolve(uint256 _winningOption) external;
    function resolveInvalid() external;
}

interface IResolvableArena {
    function freeze() external;
    function settle(uint256 _winnerIndex) external;
}

interface IMarketEndTime {
    function endTime() external view returns (uint256);
}


contract UMAResolutionOracle {

    // ══════════════════════════════════════════════════════════════
    //  ENUMS & STRUCTS
    // ══════════════════════════════════════════════════════════════

    enum MarketType { BINARY, MULTI, PARIMUTUEL, CLOB, ARENA }

    enum AssertionState { NONE, PROPOSED, SETTLED, DISPUTED, EXPIRED }

    struct MarketInfo {
        address marketAddress;
        MarketType marketType;
        bool resolved;
        uint256 rewardPool;
        string question;
    }

    struct MarketAssertion {
        bytes32 assertionId;
        address proposer;
        uint256 outcome;
        uint256 timestamp;
        AssertionState state;
        uint256 bond;
        uint256 disputeTimestamp;  // When the assertion was disputed (for 3-day timeout)
    }

    // ══════════════════════════════════════════════════════════════
    //  CONSTANTS & IMMUTABLES
    // ══════════════════════════════════════════════════════════════

    uint64 public constant LIVENESS = 7200;  // 2 hours
    uint256 public constant INVALID_OUTCOME = type(uint256).max;

    IOptimisticOracleV3 public immutable oov3;
    IERC20 public immutable currency;     // Bond currency (TestnetERC20 on testnet, WETH on mainnet)
    bool public immutable currencyIsWETH; // If true, accepts ETH and auto-wraps
    IClawshiFactory public factory;

    // ══════════════════════════════════════════════════════════════
    //  STATE
    // ══════════════════════════════════════════════════════════════

    address public owner;
    uint256 public bondAmount;

    // Per-market state
    mapping(uint256 => MarketInfo) public marketInfo;
    mapping(uint256 => MarketAssertion) public assertions;
    mapping(bytes32 => uint256) public assertionToMarket;

    uint256[] public registeredMarketIds;

    // Reward balances
    mapping(address => uint256) public pendingRewards;
    uint256 public totalPendingRewards;
    uint256 public platformFeesAccumulated;

    // ══════════════════════════════════════════════════════════════
    //  EVENTS
    // ══════════════════════════════════════════════════════════════

    event MarketRegistered(uint256 indexed marketId, address marketAddress, uint8 marketType);
    event OutcomeProposed(uint256 indexed marketId, bytes32 indexed assertionId, address proposer, uint256 outcome, uint256 bond);
    event AssertionDisputed(uint256 indexed marketId, bytes32 indexed assertionId, address disputer);
    event MarketResolved(uint256 indexed marketId, uint256 outcome, address resolver);
    event AssertionSettled(uint256 indexed marketId, bytes32 indexed assertionId, bool result);
    event RewardsClaimed(address indexed agent, uint256 amount);
    event PlatformFeesClaimed(address indexed to, uint256 amount);
    event ResolverRewardReceived(uint256 indexed marketId, uint256 amount);
    event BondUpdated(uint256 newBond);
    event MarketEndNotified(uint256 indexed marketId, address notifier);

    // ══════════════════════════════════════════════════════════════
    //  MODIFIERS
    // ══════════════════════════════════════════════════════════════

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    // ══════════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ══════════════════════════════════════════════════════════════

    constructor(
        address _oov3,
        address _currency,
        address _factory,
        uint256 _bondAmount,
        bool _currencyIsWETH
    ) {
        owner = msg.sender;
        oov3 = IOptimisticOracleV3(_oov3);
        currency = IERC20(_currency);
        currencyIsWETH = _currencyIsWETH;
        factory = IClawshiFactory(_factory);
        bondAmount = _bondAmount;

        // Pre-approve OOv3 to spend currency for bonds
        IERC20(_currency).approve(_oov3, type(uint256).max);
    }

    // ══════════════════════════════════════════════════════════════
    //  MARKET REGISTRATION
    // ══════════════════════════════════════════════════════════════

    function registerMarket(
        uint256 _marketId,
        address _marketAddress,
        MarketType _marketType,
        string calldata _question
    ) external {
        require(msg.sender == owner || msg.sender == address(factory), "Not authorized");
        require(marketInfo[_marketId].marketAddress == address(0), "Already registered");

        marketInfo[_marketId] = MarketInfo({
            marketAddress: _marketAddress,
            marketType: _marketType,
            resolved: false,
            rewardPool: 0,
            question: _question
        });

        registeredMarketIds.push(_marketId);
        emit MarketRegistered(_marketId, _marketAddress, uint8(_marketType));
    }

    // ══════════════════════════════════════════════════════════════
    //  RESOLVER REWARD DEPOSITS
    // ══════════════════════════════════════════════════════════════

    /// @notice Accept resolver reward ETH from market contracts (called via claimVoterRewards)
    function depositVoterReward(uint256 _marketId) external payable {
        require(msg.value > 0, "Zero deposit");
        marketInfo[_marketId].rewardPool += msg.value;
        emit ResolverRewardReceived(_marketId, msg.value);
    }

    function notifyMarketEnded(uint256 _marketId) external {
        MarketInfo storage m = marketInfo[_marketId];
        require(m.marketAddress != address(0), "Market not registered");
        require(!m.resolved, "Already resolved");
        emit MarketEndNotified(_marketId, msg.sender);
    }

    // ══════════════════════════════════════════════════════════════
    //  PROPOSE OUTCOME
    // ══════════════════════════════════════════════════════════════

    /**
     * @notice Propose an outcome. Post bond in currency token.
     *         If currency is WETH, send ETH and it auto-wraps.
     *         Otherwise, approve currency to this contract first.
     */
    function proposeOutcome(uint256 _marketId, uint256 _outcome) external payable returns (bytes32 assertionId) {
        MarketInfo storage m = marketInfo[_marketId];
        require(m.marketAddress != address(0), "Market not registered");
        require(!m.resolved, "Already resolved");
        require(
            block.timestamp >= IMarketEndTime(m.marketAddress).endTime(),
            "Market still open"
        );

        MarketAssertion storage a = assertions[_marketId];
        require(
            a.state == AssertionState.NONE || a.state == AssertionState.EXPIRED,
            "Assertion already active"
        );

        uint256 bond = bondAmount;
        _collectBond(msg.sender, bond);

        // Ensure OOv3 allowance
        if (currency.allowance(address(this), address(oov3)) < bond) {
            currency.approve(address(oov3), type(uint256).max);
        }

        bytes memory claim = _buildClaim(_marketId, _outcome, m.marketAddress, m.marketType, m.question);

        assertionId = oov3.assertTruth(
            claim,
            address(this),
            address(this),
            address(0),
            LIVENESS,
            address(currency),
            bond,
            oov3.defaultIdentifier(),
            bytes32(0)
        );

        a.assertionId = assertionId;
        a.proposer = msg.sender;
        a.outcome = _outcome;
        a.timestamp = block.timestamp;
        a.state = AssertionState.PROPOSED;
        a.bond = bond;

        assertionToMarket[assertionId] = _marketId;

        emit OutcomeProposed(_marketId, assertionId, msg.sender, _outcome, bond);
    }

    // ══════════════════════════════════════════════════════════════
    //  DISPUTE
    // ══════════════════════════════════════════════════════════════

    function disputeAssertion(uint256 _marketId) external payable {
        MarketAssertion storage a = assertions[_marketId];
        require(a.state == AssertionState.PROPOSED, "No active assertion");
        require(a.assertionId != bytes32(0), "No assertion ID");

        uint256 bond = a.bond;
        _collectBond(msg.sender, bond);

        if (currency.allowance(address(this), address(oov3)) < bond) {
            currency.approve(address(oov3), type(uint256).max);
        }

        oov3.disputeAssertion(a.assertionId, msg.sender);
        a.state = AssertionState.DISPUTED;
        a.disputeTimestamp = block.timestamp;

        emit AssertionDisputed(_marketId, a.assertionId, msg.sender);
    }

    // ══════════════════════════════════════════════════════════════
    //  SETTLE
    // ══════════════════════════════════════════════════════════════

    function settleAndResolve(uint256 _marketId) external {
        MarketInfo storage m = marketInfo[_marketId];
        require(!m.resolved, "Already resolved");

        MarketAssertion storage a = assertions[_marketId];
        require(
            a.state == AssertionState.PROPOSED || a.state == AssertionState.DISPUTED,
            "No active assertion"
        );

        bool result = oov3.settleAndGetAssertionResult(a.assertionId);
        a.state = AssertionState.SETTLED;

        emit AssertionSettled(_marketId, a.assertionId, result);

        if (result) {
            m.resolved = true;
            _resolveMarket(m, a.outcome);
            _distributeRewards(_marketId, a.proposer);
            emit MarketResolved(_marketId, a.outcome, a.proposer);
        } else {
            a.state = AssertionState.EXPIRED;
        }

        _sweepCurrency();
    }

    // ══════════════════════════════════════════════════════════════
    //  OOv3 CALLBACKS
    // ══════════════════════════════════════════════════════════════

    function assertionResolvedCallback(bytes32 _assertionId, bool _assertedTruthfully) external {
        require(msg.sender == address(oov3), "Not OOv3");

        uint256 marketId = assertionToMarket[_assertionId];
        if (marketId == 0) return;

        MarketInfo storage m = marketInfo[marketId];
        MarketAssertion storage a = assertions[marketId];

        if (m.resolved) return;

        a.state = AssertionState.SETTLED;
        emit AssertionSettled(marketId, _assertionId, _assertedTruthfully);

        if (_assertedTruthfully) {
            m.resolved = true;
            _resolveMarket(m, a.outcome);
            _distributeRewards(marketId, a.proposer);
            emit MarketResolved(marketId, a.outcome, a.proposer);
        } else {
            a.state = AssertionState.EXPIRED;
        }

        _sweepCurrency();
    }

    function assertionDisputedCallback(bytes32 _assertionId) external {
        require(msg.sender == address(oov3), "Not OOv3");
        uint256 marketId = assertionToMarket[_assertionId];
        if (marketId == 0) return;
        assertions[marketId].state = AssertionState.DISPUTED;
        assertions[marketId].disputeTimestamp = block.timestamp;
        emit AssertionDisputed(marketId, _assertionId, address(0));
    }

    // ══════════════════════════════════════════════════════════════
    //  INTERNAL
    // ══════════════════════════════════════════════════════════════

    /// @dev Collect bond from caller. If currency is WETH and ETH sent, wrap it.
    ///      Otherwise, transferFrom the ERC20.
    function _collectBond(address _from, uint256 _amount) internal {
        if (currencyIsWETH && msg.value > 0) {
            require(msg.value >= _amount, "Insufficient ETH for bond");
            IWETH(address(currency)).deposit{value: _amount}();
            if (msg.value > _amount) {
                (bool ok,) = _from.call{value: msg.value - _amount}("");
                require(ok, "Refund failed");
            }
        } else {
            require(
                currency.transferFrom(_from, address(this), _amount),
                "Bond transfer failed"
            );
        }
    }

    function _resolveMarket(MarketInfo storage m, uint256 _outcome) internal {
        address mAddr = m.marketAddress;

        if (m.marketType == MarketType.BINARY || m.marketType == MarketType.CLOB) {
            IResolvableBinary(mAddr).resolve(uint8(_outcome));
        }
        else if (m.marketType == MarketType.MULTI) {
            if (_outcome == INVALID_OUTCOME) {
                IResolvableMulti(mAddr).resolve(0, true);
            } else {
                IResolvableMulti(mAddr).resolve(_outcome, false);
            }
        }
        else if (m.marketType == MarketType.PARIMUTUEL) {
            if (_outcome == INVALID_OUTCOME) {
                IResolvablePari(mAddr).resolveInvalid();
            } else {
                IResolvablePari(mAddr).resolve(_outcome);
            }
        }
        else if (m.marketType == MarketType.ARENA) {
            try IResolvableArena(mAddr).freeze() {} catch {}
            IResolvableArena(mAddr).settle(_outcome);
        }
    }

    function _distributeRewards(uint256 _marketId, address _proposer) internal {
        MarketInfo storage m = marketInfo[_marketId];
        uint256 reward = m.rewardPool;
        if (reward == 0) return;

        // Full reward pool → resolver (proposer who correctly resolved)
        pendingRewards[_proposer] += reward;
        totalPendingRewards += reward;
        m.rewardPool = 0;
    }

    /// @dev Sweep any currency tokens returned after OOv3 settlement
    function _sweepCurrency() internal {
        uint256 bal = currency.balanceOf(address(this));
        if (bal > 0) {
            if (currencyIsWETH) {
                IWETH(address(currency)).withdraw(bal);
            }
            // Non-WETH: tokens stay in contract — owner can recoverCurrency()
        }
    }

    function _buildClaim(
        uint256 _marketId,
        uint256 _outcome,
        address _market,
        MarketType _marketType,
        string memory _question
    ) internal pure returns (bytes memory) {
        // Build human-readable outcome label
        string memory outcomeLabel;

        if (_outcome == INVALID_OUTCOME) {
            outcomeLabel = "INVALID (market is unanswerable or malformed)";
        } else if (_marketType == MarketType.BINARY || _marketType == MarketType.CLOB) {
            if (_outcome == 1)      outcomeLabel = "YES";
            else if (_outcome == 0) outcomeLabel = "NO";
            else if (_outcome == 2) outcomeLabel = "INVALID";
            else                    outcomeLabel = _uint2str(_outcome);
        } else {
            outcomeLabel = string(abi.encodePacked("Option #", _uint2str(_outcome)));
        }

        return abi.encodePacked(
            "The question '",
            _question,
            "' (Clawshi prediction market #",
            _uint2str(_marketId),
            " at ",
            _addr2str(_market),
            ") resolved to ",
            outcomeLabel,
            ". Affirm if this is the correct outcome."
        );
    }

    // ══════════════════════════════════════════════════════════════
    //  CLAIM REWARDS
    // ══════════════════════════════════════════════════════════════

    function claimRewards() external {
        uint256 amount = pendingRewards[msg.sender];
        require(amount > 0, "No rewards");
        pendingRewards[msg.sender] = 0;
        totalPendingRewards -= amount;

        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "Transfer failed");

        emit RewardsClaimed(msg.sender, amount);
    }

    function claimPlatformFees() external onlyOwner {
        uint256 amount = platformFeesAccumulated;
        require(amount > 0, "No fees");
        platformFeesAccumulated = 0;

        (bool ok,) = owner.call{value: amount}("");
        require(ok, "Transfer failed");

        emit PlatformFeesClaimed(owner, amount);
    }

    // ══════════════════════════════════════════════════════════════
    //  VIEW FUNCTIONS
    // ══════════════════════════════════════════════════════════════

    function getAssertion(uint256 _marketId) external view returns (
        bytes32 assertionId,
        address proposer,
        uint256 outcome,
        uint256 timestamp,
        AssertionState state,
        uint256 bond,
        uint256 disputeTimestamp
    ) {
        MarketAssertion storage a = assertions[_marketId];
        return (a.assertionId, a.proposer, a.outcome, a.timestamp, a.state, a.bond, a.disputeTimestamp);
    }

    function getMarketResolutionState(uint256 _marketId) external view returns (
        bool resolved,
        uint256 rewardPool,
        AssertionState currentState
    ) {
        MarketInfo storage m = marketInfo[_marketId];
        MarketAssertion storage a = assertions[_marketId];
        return (m.resolved, m.rewardPool, a.state);
    }

    function getRegisteredMarketCount() external view returns (uint256) {
        return registeredMarketIds.length;
    }

    function canSettle(uint256 _marketId) external view returns (bool) {
        MarketAssertion storage a = assertions[_marketId];
        if (a.state != AssertionState.PROPOSED && a.state != AssertionState.DISPUTED) return false;
        if (a.assertionId == bytes32(0)) return false;

        IOptimisticOracleV3.Assertion memory oa = oov3.getAssertion(a.assertionId);
        // Can settle if past expiration and not yet settled
        return !oa.settled && block.timestamp >= oa.expirationTime;
    }

    function isDisputable(uint256 _marketId) external view returns (bool) {
        MarketAssertion storage a = assertions[_marketId];
        if (a.state != AssertionState.PROPOSED) return false;
        if (a.assertionId == bytes32(0)) return false;

        IOptimisticOracleV3.Assertion memory oa = oov3.getAssertion(a.assertionId);
        return !oa.settled && block.timestamp < oa.expirationTime;
    }

    function getMinBond() external view returns (uint256) {
        return oov3.getMinimumBond(address(currency));
    }

    function getCurrencyInfo() external view returns (address curr, bool isWETH, uint256 bond) {
        return (address(currency), currencyIsWETH, bondAmount);
    }

    /**
     * @notice Returns true if emergency resolve conditions are met:
     *         (a) Assertion was disputed and UMA DVM hasn't returned in 3 days, OR
     *         (b) UMA DVM returned false — assertion rejected (EXPIRED state),
     *             meaning the proposed outcome was wrong / question unanswerable.
     */
    function canEmergencyResolve(uint256 _marketId) external view returns (bool) {
        MarketInfo storage m = marketInfo[_marketId];
        if (m.resolved) return false;

        MarketAssertion storage a = assertions[_marketId];

        // (a) Disputed and 3 days have passed with no DVM result
        if (a.state == AssertionState.DISPUTED &&
            a.disputeTimestamp > 0 &&
            block.timestamp >= a.disputeTimestamp + 3 days) {
            return true;
        }

        // (b) DVM returned false — assertion was rejected
        if (a.state == AssertionState.EXPIRED) {
            return true;
        }

        return false;
    }

    // ══════════════════════════════════════════════════════════════
    //  ADMIN
    // ══════════════════════════════════════════════════════════════

    function setBondAmount(uint256 _bond) external onlyOwner {
        bondAmount = _bond;
        emit BondUpdated(_bond);
    }

    function setFactory(address _factory) external onlyOwner {
        factory = IClawshiFactory(_factory);
    }

    function transferOwnership(address _newOwner) external onlyOwner {
        require(_newOwner != address(0), "Zero address");
        owner = _newOwner;
    }

    /**
     * @notice Emergency: owner can manually resolve a market if UMA gets stuck.
     */
    function emergencyResolve(uint256 _marketId, uint256 _outcome) external onlyOwner {
        MarketInfo storage m = marketInfo[_marketId];
        require(!m.resolved, "Already resolved");

        m.resolved = true;
        _resolveMarket(m, _outcome);

        emit MarketResolved(_marketId, _outcome, msg.sender);
    }

    /// @notice Recover any currency tokens stuck in the contract
    function recoverCurrency() external onlyOwner {
        uint256 bal = currency.balanceOf(address(this));
        if (bal > 0) currency.transfer(owner, bal);
    }

    // ══════════════════════════════════════════════════════════════
    //  UTILITIES
    // ══════════════════════════════════════════════════════════════

    function _uint2str(uint256 _i) internal pure returns (string memory) {
        if (_i == 0) return "0";
        uint256 j = _i;
        uint256 len;
        while (j != 0) { len++; j /= 10; }
        bytes memory bstr = new bytes(len);
        uint256 k = len;
        while (_i != 0) { k--; bstr[k] = bytes1(uint8(48 + _i % 10)); _i /= 10; }
        return string(bstr);
    }

    function _addr2str(address _a) internal pure returns (string memory) {
        bytes memory s = new bytes(42);
        s[0] = "0";
        s[1] = "x";
        for (uint256 i = 0; i < 20; i++) {
            uint8 b = uint8(uint160(_a) >> (8 * (19 - i)));
            s[2 + i * 2] = _hex(b >> 4);
            s[3 + i * 2] = _hex(b & 0x0f);
        }
        return string(s);
    }

    function _hex(uint8 _b) internal pure returns (bytes1) {
        return _b < 10 ? bytes1(_b + 48) : bytes1(_b + 87);
    }

    receive() external payable {}
}
