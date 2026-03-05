// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ParimutuelMarket
 * @notice Simple pot-splitting prediction market (parimutuel).
 *         All bets go into one pot. Winners split proportionally by bet size.
 *         No AMM, no LP, no sell — just bet and redeem.
 *         Designed for private/friend-group markets.
 *
 *         Payout = (userBet / totalWinningBets) × totalPot × (1 - fee)
 */
import "./IVotingOracle.sol";

contract ParimutuelMarket {
    uint256 public marketId;
    address public creator;
    address public resolver;
    string  public question;
    string  public categories;
    uint256 public endTime;
    uint256 public resolutionTime;
    uint256 public protocolFeeBps;   // e.g. 100 = 1%
    address public protocolFeeRecipient;
    bool    public isPrivate;

    uint256 public optionCount;
    string[] public optionLabels;

    // Pot tracking
    uint256 public totalPot;
    uint256[] public optionTotals;                          // total ETH bet per option
    mapping(address => mapping(uint256 => uint256)) public bets; // user => option => amount

    // Resolution
    bool    public resolved;
    bool    public invalid;
    uint256 public winningOption;

    // Redemption
    mapping(address => bool) public redeemed;
    bool public feeTaken;

    // ── Voter reward (decentralized resolution) ──
    address public votingContract;
    uint256 public voterRewardBps;   // % of protocol cut → voting contract (bps)

    // Participants
    mapping(address => bool) private _isPart;
    address[] public participants;

    event BetPlaced(address indexed bettor, uint256 option, uint256 amount);
    event MarketResolved(uint256 winningOption, bool invalid, address resolvedBy);
    event Redeemed(address indexed user, uint256 payout);

    modifier onlyCreatorOrResolver() {
        require(
            msg.sender == creator || msg.sender == resolver ||
            (msg.sender == votingContract && votingContract != address(0)),
            "Not authorized"
        );
        _;
    }

    modifier marketOpen() {
        require(block.timestamp < endTime, "Market closed");
        require(!resolved, "Already resolved");
        _;
    }

    constructor(
        uint256 _marketId,
        address _creator,
        address _resolver,
        string memory _question,
        string[] memory _options,
        uint256 _endTime,
        uint256 _resolutionTime,
        uint256 _protocolFeeBps,
        address _protocolFeeRecipient,
        string memory _categories,
        bool _isPrivate
    ) {
        require(_options.length >= 2 && _options.length <= 20, "2-20 options");
        require(_endTime > block.timestamp, "End must be future");
        require(_resolutionTime > _endTime, "Res must be after end");
        require(_protocolFeeBps <= 500, "Fee too high");

        marketId = _marketId;
        creator = _creator;
        resolver = _resolver;
        question = _question;
        endTime = _endTime;
        resolutionTime = _resolutionTime;
        protocolFeeBps = _protocolFeeBps;
        protocolFeeRecipient = _protocolFeeRecipient;
        categories = _categories;
        isPrivate = _isPrivate;
        optionCount = _options.length;

        for (uint256 i = 0; i < _options.length; i++) {
            optionLabels.push(_options[i]);
            optionTotals.push(0);
        }
    }

    /// @notice Place a bet on an option
    function bet(uint256 _option) external payable marketOpen {
        require(_option < optionCount, "Invalid option");
        require(msg.value > 0, "Must send ETH");

        bets[msg.sender][_option] += msg.value;
        optionTotals[_option] += msg.value;
        totalPot += msg.value;

        if (!_isPart[msg.sender]) {
            _isPart[msg.sender] = true;
            participants.push(msg.sender);
        }

        emit BetPlaced(msg.sender, _option, msg.value);
    }

    /// @notice Resolve the market with a winning option (creator/resolver only)
    function resolve(uint256 _winningOption) external onlyCreatorOrResolver {
        require(!resolved, "Already resolved");
        require(_winningOption < optionCount, "Invalid option");
        resolved = true;
        winningOption = _winningOption;
        _extractFees();
        emit MarketResolved(_winningOption, false, msg.sender);
    }

    /// @notice Resolve as invalid — everyone gets refunded proportionally
    function resolveInvalid() external onlyCreatorOrResolver {
        require(!resolved, "Already resolved");
        resolved = true;
        invalid = true;
        // No fees on invalid
        emit MarketResolved(0, true, msg.sender);
    }

    /// @notice Extract protocol + creator fees (60/40 split) with voter reward
    function _extractFees() internal {
        if (feeTaken || totalPot == 0) return;
        feeTaken = true;
        uint256 fee = (totalPot * protocolFeeBps) / 10_000;
        if (fee == 0) return;
        uint256 protocolShare = (fee * 60) / 100;
        uint256 creatorShare = fee - protocolShare;
        uint256 voterShare = (protocolShare * voterRewardBps) / 10000;
        uint256 netProtocolShare = protocolShare - voterShare;
        if (netProtocolShare > 0) {
            (bool s1,) = protocolFeeRecipient.call{value: netProtocolShare}("");
            require(s1, "Protocol fee failed");
        }
        if (creatorShare > 0) {
            (bool s2,) = creator.call{value: creatorShare}("");
            require(s2, "Creator fee failed");
        }
        if (voterShare > 0 && votingContract != address(0)) {
            IVotingOracle(votingContract).depositVoterReward{value: voterShare}(marketId);
        } else if (voterShare > 0) {
            // No voting contract set — send to protocol
            (bool s3,) = protocolFeeRecipient.call{value: voterShare}("");
            require(s3, "Voter fee fallback failed");
        }
    }

    /// @notice Configure decentralized resolution voting rewards
    function setVotingConfig(address _votingContract, uint256 _voterRewardBps) external {
        if (votingContract != address(0)) {
            require(msg.sender == resolver || msg.sender == creator, "Not authorized");
        }
        require(_voterRewardBps <= 10000, "Too high");
        votingContract = _votingContract;
        voterRewardBps = _voterRewardBps;
    }

    /// @notice Redeem winnings (or refund if invalid)
    function redeem() external {
        require(resolved, "Not resolved");
        require(!redeemed[msg.sender], "Already redeemed");
        redeemed[msg.sender] = true;

        uint256 payout;
        if (invalid) {
            // Refund proportionally by total bets
            uint256 userTotal = 0;
            for (uint256 i = 0; i < optionCount; i++) {
                userTotal += bets[msg.sender][i];
            }
            // Pool after no fee extraction (invalid = full refund)
            payout = totalPot > 0 ? (userTotal * address(this).balance) / totalPot : 0;
        } else {
            uint256 winBet = bets[msg.sender][winningOption];
            uint256 winPool = optionTotals[winningOption];
            // Payout = (userWinBet / totalWinBets) × remaining pool
            payout = winPool > 0 ? (winBet * address(this).balance) / winPool : 0;
        }

        if (payout > 0) {
            (bool ok,) = msg.sender.call{value: payout}("");
            require(ok, "Transfer failed");
        }

        emit Redeemed(msg.sender, payout);
    }

    // ══════════════════════════════════════════
    // VIEW FUNCTIONS
    // ══════════════════════════════════════════

    /// @notice Get implied odds from bet ratios (basis points, sum ≈ 10000)
    function getOdds() external view returns (uint256[] memory) {
        uint256[] memory odds = new uint256[](optionCount);
        if (totalPot == 0) {
            // Equal odds when no bets
            for (uint256 i = 0; i < optionCount; i++) {
                odds[i] = 10_000 / optionCount;
            }
            return odds;
        }
        for (uint256 i = 0; i < optionCount; i++) {
            odds[i] = (optionTotals[i] * 10_000) / totalPot;
        }
        return odds;
    }

    /// @notice Get user's bets for each option
    function getPosition(address _user) external view returns (uint256[] memory) {
        uint256[] memory pos = new uint256[](optionCount);
        for (uint256 i = 0; i < optionCount; i++) {
            pos[i] = bets[_user][i];
        }
        return pos;
    }

    /// @notice Get market summary
    function getMarketInfo() external view returns (
        string memory _question,
        uint256 _endTime,
        uint256 _optionCount,
        uint256 _totalPot,
        bool    _resolved,
        bool    _invalid,
        uint256 _winningOption,
        address _creator
    ) {
        return (question, endTime, optionCount, totalPot, resolved, invalid, winningOption, creator);
    }

    /// @notice Get all options data
    function getOptions() external view returns (
        string[] memory labels,
        uint256[] memory totals
    ) {
        return (optionLabels, optionTotals);
    }

    function getParticipantCount() external view returns (uint256) {
        return participants.length;
    }
}
