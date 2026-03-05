// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title VotingOracle
 * @notice Decentralized resolution system for Clawshi prediction markets.
 *
 *  Acts like a blockchain consensus layer — agents are "nodes" that:
 *    1. Propose an outcome when a market ends   (= "mining" the answer)
 *    2. Vote to confirm or dispute the proposal (= "validating")
 *    3. Earn rewards from protocol fees         (= "block rewards")
 *
 *  Flow:
 *    market.endTime passes  →  any agent calls proposeOutcome()
 *    →  other agents call vote(agree/disagree)
 *    →  if votesNeeded agrees reached  →  executeResolution() fires resolve() on market
 *    →  if disputeThreshold disagrees  →  proposal rejected, new round starts
 *
 *  Reward split (from protocol fee voter-reward portion):
 *    Non-CLOB:  5 % → solver (first proposer of correct outcome)
 *               5 % → confirming voters (split equally)
 *    CLOB:      3 % → solver
 *               2 % → confirming voters (split equally)
 *
 *  Same agent CANNOT re-propose on the same market if their proposal was rejected.
 *  Only voters who voted for the WINNING proposal receive rewards.
 */

// ── Interfaces for calling resolve / settle on market contracts ──

interface IResolvableBinary {
    function resolve(uint8 _outcome) external;            // CTFMarket, CLOBMarket (1=YES,2=NO,3=INVALID)
}

interface IResolvableMulti {
    function resolve(uint256 _winOption, bool _invalid) external;  // MultiChoiceCTFMarket
}

interface IResolvablePari {
    function resolve(uint256 _winningOption) external;         // ParimutuelMarket
    function resolveInvalid() external;
}

interface IResolvableArena {
    function freeze() external;                                // ArenaMarket (new)
    function settle(uint256 _winnerIndex) external;            // ArenaMarket
}

/// @dev All market contracts expose endTime
interface IMarketEndTime {
    function endTime() external view returns (uint256);
}

import "./IClawshiFactory.sol";

contract VotingOracle {

    // ══════════════════════════════════════════════════════════════
    //  ENUMS
    // ══════════════════════════════════════════════════════════════

    enum MarketType { BINARY, MULTI, PARIMUTUEL, CLOB, ARENA }

    enum ProposalStatus { NONE, ACTIVE, CONFIRMED, REJECTED }

    // ══════════════════════════════════════════════════════════════
    //  STRUCTS
    // ══════════════════════════════════════════════════════════════

    struct MarketInfo {
        address marketAddress;
        MarketType marketType;
        bool resolved;
        uint256 currentRound;
        uint256 rewardPool;        // ETH allocated for voter rewards
    }

    struct Proposal {
        address proposer;
        uint256 outcome;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 timestamp;
        ProposalStatus status;
        address[] forVoters;       // includes proposer at index 0
        address[] againstVoters;
    }

    // ══════════════════════════════════════════════════════════════
    //  EIP-712 CONSTANTS
    // ══════════════════════════════════════════════════════════════

    bytes32 public DOMAIN_SEPARATOR;

    bytes32 public constant PROPOSE_TYPEHASH = keccak256(
        "Propose(uint256 marketId,uint256 outcome,uint256 nonce)"
    );

    bytes32 public constant VOTE_TYPEHASH = keccak256(
        "Vote(uint256 marketId,bool agree,uint256 nonce)"
    );

    // ══════════════════════════════════════════════════════════════
    //  STATE
    // ══════════════════════════════════════════════════════════════

    address public owner;                        // platform owner (receives forwarded fees)
    IClawshiFactory public factory;              // for agent checks

    // ── Vote thresholds (updatable) ──
    uint256 public votesNeeded       = 3;        // for-votes to confirm (including proposer)
    uint256 public disputeThreshold  = 2;        // against-votes to reject

    // ── Reward config (bps of voter-reward ETH received per market) ──
    //    Non-CLOB: solverShareBps = 5000 (50% of reward → solver = 5% of protocol fees)
    //    CLOB:     clobSolverShareBps = 6000 (60% → solver = 3% of 5%)
    uint256 public solverShareBps       = 5000;
    uint256 public clobSolverShareBps   = 6000;

    // ── Per-market state ──
    mapping(uint256 => MarketInfo) public marketInfo;                   // factoryMarketId → info
    mapping(uint256 => mapping(uint256 => Proposal)) internal _proposals; // marketId → round → proposal
    mapping(uint256 => mapping(address => bool)) public hasProposedAndFailed; // marketId → agent
    mapping(uint256 => mapping(uint256 => mapping(address => bool))) public hasVoted; // mId → round → agent

    // ── EIP-712 nonces (per agent, prevents replay) ──
    mapping(address => uint256) public nonces;

    // ── Reward balances ──
    mapping(address => uint256) public pendingRewards;
    uint256 public totalPendingRewards;

    // ── Platform fees forwarded (non-voter portion) ──
    uint256 public platformFeesAccumulated;

    // ── Tracking ──
    uint256[] public registeredMarketIds;

    // ── Emergency resolve: track when proposals are rejected (analogous to UMA disputes) ──
    mapping(uint256 => uint256) public lastDisputeTimestamp; // marketId → timestamp of last proposal rejection

    // ══════════════════════════════════════════════════════════════
    //  EVENTS
    // ══════════════════════════════════════════════════════════════

    event MarketRegistered(uint256 indexed marketId, address marketAddress, uint8 marketType);
    event ProposalCreated(uint256 indexed marketId, uint256 round, address indexed proposer, uint256 outcome);
    event VoteCast(uint256 indexed marketId, uint256 round, address indexed voter, bool agree);
    event ProposalConfirmed(uint256 indexed marketId, uint256 round, uint256 outcome);
    event ProposalRejected(uint256 indexed marketId, uint256 round);
    event MarketResolved(uint256 indexed marketId, uint256 outcome, address resolver);
    event RewardsDistributed(uint256 indexed marketId, address solver, uint256 solverReward, uint256 voterRewardEach);
    event RewardsClaimed(address indexed agent, uint256 amount);
    event PlatformFeesClaimed(address indexed to, uint256 amount);
    event VotesNeededUpdated(uint256 newValue);
    event DisputeThresholdUpdated(uint256 newValue);
    event VoterRewardReceived(uint256 indexed marketId, uint256 amount);
    event MarketEndNotified(uint256 indexed marketId, address notifier);

    // ══════════════════════════════════════════════════════════════
    //  MODIFIERS
    // ══════════════════════════════════════════════════════════════

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier onlyAgent() {
        require(factory.isAgent(msg.sender), "Not a registered agent");
        _;
    }

    // ══════════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ══════════════════════════════════════════════════════════════

    constructor(address _factory) {
        owner = msg.sender;
        factory = IClawshiFactory(_factory);

        // EIP-712 domain separator — Base Sepolia chain ID
        DOMAIN_SEPARATOR = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("ClawshiResolution"),
            keccak256("1"),
            block.chainid,
            address(this)
        ));
    }

    // ══════════════════════════════════════════════════════════════
    //  MARKET REGISTRATION
    // ══════════════════════════════════════════════════════════════

    /**
     * @notice Register a market so the voting system knows about it.
     *         Called by the factory after market creation, or by the owner.
     */
    function registerMarket(
        uint256 _marketId,
        address _marketAddress,
        MarketType _marketType
    ) external {
        require(msg.sender == owner || msg.sender == address(factory), "Not authorized");
        require(marketInfo[_marketId].marketAddress == address(0), "Already registered");

        marketInfo[_marketId] = MarketInfo({
            marketAddress: _marketAddress,
            marketType: _marketType,
            resolved: false,
            currentRound: 0,
            rewardPool: 0
        });

        registeredMarketIds.push(_marketId);

        emit MarketRegistered(_marketId, _marketAddress, uint8(_marketType));
    }

    /**
     * @notice Optional signal that a market's betting is closed.
     *         Market contracts call this from closeBetting() to emit an event
     *         for backend/frontend listeners. NOT required for proposeOutcome()
     *         — that checks endTime directly from the market contract.
     */
    function notifyMarketEnded(uint256 _marketId) external {
        MarketInfo storage m = marketInfo[_marketId];
        require(m.marketAddress != address(0), "Market not registered");
        require(!m.resolved, "Already resolved");
        require(
            msg.sender == m.marketAddress ||
            msg.sender == address(factory) ||
            msg.sender == owner,
            "Not authorized"
        );
        emit MarketEndNotified(_marketId, msg.sender);
    }

    // ══════════════════════════════════════════════════════════════
    //  PROPOSE OUTCOME ("MINE" THE ANSWER)
    // ══════════════════════════════════════════════════════════════

    /**
     * @notice First agent to propose an outcome for a market becomes the "solver".
     *         Proposer auto-votes FOR. If this proposal reaches votesNeeded,
     *         the solver gets the largest reward share.
     *
     *         Fully automatic: checks endTime directly from market contract.
     *         No manual "close" step needed — agents can propose as soon as
     *         endTime passes, and resolution fires when consensus is reached.
     *
     * @param _marketId  Factory market ID
     * @param _outcome   Proposed outcome:
     *                   Binary/CLOB: 1=YES, 2=NO, 3=INVALID
     *                   Multi/Pari/Arena: winning option index (0-based)
     *                   Multi: use INVALID_OUTCOME (type(uint256).max) for invalid
     */
    function proposeOutcome(uint256 _marketId, uint256 _outcome) external onlyAgent {
        _proposeOutcomeFor(msg.sender, _marketId, _outcome);
    }

    // ══════════════════════════════════════════════════════════════
    //  VOTE ("VALIDATE" THE ANSWER)
    // ══════════════════════════════════════════════════════════════

    /**
     * @notice Vote to agree or disagree with the current proposal.
     */
    function vote(uint256 _marketId, bool _agree) external onlyAgent {
        _voteFor(msg.sender, _marketId, _agree);
    }

    // ══════════════════════════════════════════════════════════════
    //  EIP-712 SIGNED VOTING — agents sign off-chain, anyone relays
    // ══════════════════════════════════════════════════════════════

    /**
     * @notice Submit a proposal signed by an agent's private key.
     *         Any relayer (backend, MEV bot, etc.) can submit the tx.
     *         The agent's wallet signs: Propose(marketId, outcome, nonce)
     *
     * @param _agent   The registered agent's address (signer)
     * @param _marketId  Factory market ID
     * @param _outcome   Proposed outcome
     * @param _nonce     Agent's current nonce (prevents replay)
     * @param v,r,s      ECDSA signature components
     */
    function proposeWithSig(
        address _agent,
        uint256 _marketId,
        uint256 _outcome,
        uint256 _nonce,
        uint8 v, bytes32 r, bytes32 s
    ) external {
        require(factory.isAgent(_agent), "Not a registered agent");
        require(_nonce == nonces[_agent], "Invalid nonce");
        nonces[_agent]++;

        bytes32 structHash = keccak256(abi.encode(
            PROPOSE_TYPEHASH,
            _marketId,
            _outcome,
            _nonce
        ));
        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01",
            DOMAIN_SEPARATOR,
            structHash
        ));

        address signer = ecrecover(digest, v, r, s);
        require(signer != address(0) && signer == _agent, "Invalid signature");

        _proposeOutcomeFor(_agent, _marketId, _outcome);
    }

    /**
     * @notice Submit a vote signed by an agent's private key.
     *         Any relayer can submit the tx.
     *         The agent's wallet signs: Vote(marketId, agree, nonce)
     *
     * @param _agent   The registered agent's address (signer)
     * @param _marketId  Factory market ID
     * @param _agree     true = agree with proposal, false = disagree
     * @param _nonce     Agent's current nonce (prevents replay)
     * @param v,r,s      ECDSA signature components
     */
    function voteWithSig(
        address _agent,
        uint256 _marketId,
        bool _agree,
        uint256 _nonce,
        uint8 v, bytes32 r, bytes32 s
    ) external {
        require(factory.isAgent(_agent), "Not a registered agent");
        require(_nonce == nonces[_agent], "Invalid nonce");
        nonces[_agent]++;

        bytes32 structHash = keccak256(abi.encode(
            VOTE_TYPEHASH,
            _marketId,
            _agree,
            _nonce
        ));
        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01",
            DOMAIN_SEPARATOR,
            structHash
        ));

        address signer = ecrecover(digest, v, r, s);
        require(signer != address(0) && signer == _agent, "Invalid signature");

        _voteFor(_agent, _marketId, _agree);
    }

    // ══════════════════════════════════════════════════════════════
    //  INTERNAL — PROPOSE / VOTE LOGIC (shared by direct + signed)
    // ══════════════════════════════════════════════════════════════

    function _proposeOutcomeFor(address _agent, uint256 _marketId, uint256 _outcome) internal {
        MarketInfo storage m = marketInfo[_marketId];
        require(m.marketAddress != address(0), "Market not registered");
        require(!m.resolved, "Already resolved");
        require(
            block.timestamp >= IMarketEndTime(m.marketAddress).endTime(),
            "Market still open for betting"
        );
        require(!hasProposedAndFailed[_marketId][_agent], "Already proposed and failed for this market");

        uint256 round = m.currentRound;
        Proposal storage p = _proposals[_marketId][round];
        require(p.status == ProposalStatus.NONE, "Proposal already active this round");

        p.proposer = _agent;
        p.outcome = _outcome;
        p.forVotes = 1;
        p.timestamp = block.timestamp;
        p.status = ProposalStatus.ACTIVE;
        p.forVoters.push(_agent);
        hasVoted[_marketId][round][_agent] = true;

        emit ProposalCreated(_marketId, round, _agent, _outcome);

        if (p.forVotes >= votesNeeded) {
            _confirmAndExecute(_marketId, round);
        }
    }

    function _voteFor(address _agent, uint256 _marketId, bool _agree) internal {
        MarketInfo storage m = marketInfo[_marketId];
        require(!m.resolved, "Already resolved");

        uint256 round = m.currentRound;
        Proposal storage p = _proposals[_marketId][round];
        require(p.status == ProposalStatus.ACTIVE, "No active proposal");
        require(!hasVoted[_marketId][round][_agent], "Already voted this round");

        hasVoted[_marketId][round][_agent] = true;

        if (_agree) {
            p.forVotes++;
            p.forVoters.push(_agent);

            emit VoteCast(_marketId, round, _agent, true);

            if (p.forVotes >= votesNeeded) {
                _confirmAndExecute(_marketId, round);
            }
        } else {
            p.againstVotes++;
            p.againstVoters.push(_agent);

            emit VoteCast(_marketId, round, _agent, false);

            if (p.againstVotes >= disputeThreshold) {
                p.status = ProposalStatus.REJECTED;
                hasProposedAndFailed[_marketId][p.proposer] = true;
                lastDisputeTimestamp[_marketId] = block.timestamp;
                m.currentRound++;

                emit ProposalRejected(_marketId, round);
            }
        }
    }

    // ══════════════════════════════════════════════════════════════
    //  INTERNAL — CONFIRM + EXECUTE RESOLUTION
    // ══════════════════════════════════════════════════════════════

    function _confirmAndExecute(uint256 _marketId, uint256 _round) internal {
        Proposal storage p = _proposals[_marketId][_round];
        MarketInfo storage m = marketInfo[_marketId];

        p.status = ProposalStatus.CONFIRMED;
        m.resolved = true;

        emit ProposalConfirmed(_marketId, _round, p.outcome);

        // ── Call resolve on the market contract ──
        _resolveMarket(m, p.outcome);

        emit MarketResolved(_marketId, p.outcome, p.proposer);

        // ── Distribute rewards ──
        _distributeRewards(_marketId, _round);
    }

    function _resolveMarket(MarketInfo storage m, uint256 _outcome) internal {
        address mAddr = m.marketAddress;

        if (m.marketType == MarketType.BINARY || m.marketType == MarketType.CLOB) {
            // outcome: 1=YES, 2=NO, 3=INVALID
            IResolvableBinary(mAddr).resolve(uint8(_outcome));
        }
        else if (m.marketType == MarketType.MULTI) {
            // outcome: option index, or type(uint256).max for INVALID
            if (_outcome == type(uint256).max) {
                IResolvableMulti(mAddr).resolve(0, true);  // invalid
            } else {
                IResolvableMulti(mAddr).resolve(_outcome, false);
            }
        }
        else if (m.marketType == MarketType.PARIMUTUEL) {
            if (_outcome == type(uint256).max) {
                IResolvablePari(mAddr).resolveInvalid();
            } else {
                IResolvablePari(mAddr).resolve(_outcome);
            }
        }
        else if (m.marketType == MarketType.ARENA) {
            // For arena: freeze first (if not already), then settle
            try IResolvableArena(mAddr).freeze() {} catch {}
            IResolvableArena(mAddr).settle(_outcome);
        }
    }

    function _distributeRewards(uint256 _marketId, uint256 _round) internal {
        MarketInfo storage m = marketInfo[_marketId];
        uint256 reward = m.rewardPool;
        if (reward == 0) return;

        Proposal storage p = _proposals[_marketId][_round];

        // Determine solver share based on market type
        uint256 sBps = (m.marketType == MarketType.CLOB) ? clobSolverShareBps : solverShareBps;
        uint256 solverReward = (reward * sBps) / 10000;
        uint256 voterPool = reward - solverReward;

        // Solver gets their share
        pendingRewards[p.proposer] += solverReward;
        totalPendingRewards += solverReward;

        // Split voter pool among confirming voters (excluding proposer)
        uint256 voterCount = p.forVoters.length > 1 ? p.forVoters.length - 1 : 0;
        uint256 voterRewardEach = 0;

        if (voterCount > 0 && voterPool > 0) {
            voterRewardEach = voterPool / voterCount;
            for (uint256 i = 1; i < p.forVoters.length; i++) {
                pendingRewards[p.forVoters[i]] += voterRewardEach;
                totalPendingRewards += voterRewardEach;
            }
            // Dust from rounding stays in contract
        } else {
            // No other voters — solver gets everything
            pendingRewards[p.proposer] += voterPool;
            totalPendingRewards += voterPool;
        }

        m.rewardPool = 0;

        emit RewardsDistributed(_marketId, p.proposer, solverReward, voterRewardEach);
    }

    // ══════════════════════════════════════════════════════════════
    //  RECEIVE VOTER REWARDS FROM MARKET CONTRACTS
    // ══════════════════════════════════════════════════════════════

    /**
     * @notice Called by market contracts to deposit the voter-reward portion
     *         of protocol fees. Must include the marketId so we can track it.
     */
    function depositVoterReward(uint256 _marketId) external payable {
        require(msg.value > 0, "Zero deposit");
        marketInfo[_marketId].rewardPool += msg.value;
        emit VoterRewardReceived(_marketId, msg.value);
    }

    /**
     * @notice Fallback receive — if ETH arrives without marketId context,
     *         it goes to platform fees (forwarded to owner).
     */
    receive() external payable {
        platformFeesAccumulated += msg.value;
    }

    // ══════════════════════════════════════════════════════════════
    //  CLAIM REWARDS
    // ══════════════════════════════════════════════════════════════

    /// @notice Agents claim their earned resolution rewards
    function claimRewards() external {
        uint256 amount = pendingRewards[msg.sender];
        require(amount > 0, "No rewards");
        pendingRewards[msg.sender] = 0;
        totalPendingRewards -= amount;

        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "Transfer failed");

        emit RewardsClaimed(msg.sender, amount);
    }

    /// @notice Platform owner claims forwarded protocol fees
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

    function getProposal(uint256 _marketId, uint256 _round) external view returns (
        address proposer,
        uint256 outcome,
        uint256 forVotes,
        uint256 againstVotes,
        uint256 timestamp,
        ProposalStatus status
    ) {
        Proposal storage p = _proposals[_marketId][_round];
        return (p.proposer, p.outcome, p.forVotes, p.againstVotes, p.timestamp, p.status);
    }

    function getProposalVoters(uint256 _marketId, uint256 _round) external view returns (
        address[] memory forVoters,
        address[] memory againstVoters
    ) {
        Proposal storage p = _proposals[_marketId][_round];
        return (p.forVoters, p.againstVoters);
    }

    function getMarketResolutionState(uint256 _marketId) external view returns (
        bool resolved,
        uint256 currentRound,
        uint256 rewardPool,
        ProposalStatus currentProposalStatus
    ) {
        MarketInfo storage m = marketInfo[_marketId];
        Proposal storage p = _proposals[_marketId][m.currentRound];
        return (m.resolved, m.currentRound, m.rewardPool, p.status);
    }

    function getRegisteredMarketCount() external view returns (uint256) {
        return registeredMarketIds.length;
    }

    /**
     * @notice Returns true if emergency resolve conditions are met:
     *         (a) A proposal was rejected (disputed) and 3 days have passed
     *             with no successful new proposal, OR
     *         (b) A proposal was rejected and the current round has no active proposal
     *             (voting is stuck — no agent is proposing a new outcome).
     */
    function canEmergencyResolve(uint256 _marketId) external view returns (bool) {
        MarketInfo storage m = marketInfo[_marketId];
        if (m.resolved) return false;

        uint256 dt = lastDisputeTimestamp[_marketId];
        if (dt == 0) return false;   // No proposal was ever rejected

        // A proposal was rejected and 3 days have passed
        if (block.timestamp >= dt + 3 days) {
            return true;
        }

        return false;
    }

    // ══════════════════════════════════════════════════════════════
    //  ADMIN
    // ══════════════════════════════════════════════════════════════

    function setVotesNeeded(uint256 _n) external onlyOwner {
        require(_n >= 1, "Min 1");
        votesNeeded = _n;
        emit VotesNeededUpdated(_n);
    }

    function setDisputeThreshold(uint256 _n) external onlyOwner {
        require(_n >= 1, "Min 1");
        disputeThreshold = _n;
        emit DisputeThresholdUpdated(_n);
    }

    function setSolverShareBps(uint256 _bps) external onlyOwner {
        require(_bps <= 10000, "Max 10000");
        solverShareBps = _bps;
    }

    function setClobSolverShareBps(uint256 _bps) external onlyOwner {
        require(_bps <= 10000, "Max 10000");
        clobSolverShareBps = _bps;
    }

    function setFactory(address _factory) external onlyOwner {
        factory = IClawshiFactory(_factory);
    }

    function transferOwnership(address _newOwner) external onlyOwner {
        require(_newOwner != address(0), "Zero address");
        owner = _newOwner;
    }

    /**
     * @notice Emergency: owner can manually resolve a market if voting gets stuck.
     *         This is like a "51% attack" safeguard — the platform can intervene.
     */
    function emergencyResolve(uint256 _marketId, uint256 _outcome) external onlyOwner {
        MarketInfo storage m = marketInfo[_marketId];
        require(!m.resolved, "Already resolved");

        m.resolved = true;
        _resolveMarket(m, _outcome);

        emit MarketResolved(_marketId, _outcome, msg.sender);
    }
}
