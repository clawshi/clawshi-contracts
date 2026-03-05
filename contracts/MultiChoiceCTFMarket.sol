// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title MultiChoiceCTFMarket — N-option FPMM with token-set collateral
 * @notice 2-20 option prediction market with GUARANTEED payouts.
 *
 *  Same design as CTFMarket but generalized to N outcomes:
 *    - AMM holds inventories of N outcome tokens
 *    - Buy:  ETH → mint complete sets → sell complement into AMM
 *    - Sell: Return tokens → merge excess complete sets → release ETH
 *    - Uses binary search for N-option sell (quadratic only works for N=2)
 *    - Overflow-safe: chain multiplication avoids 256-bit overflow for any N
 *
 *  Settlement: 1 winning token = exactly 1 ETH (guaranteed by collateral)
 */
import "./IVotingOracle.sol";

contract MultiChoiceCTFMarket {

    // ──────────────  CONSTANTS  ──────────────
    uint256 public constant MAX_PROTOCOL_FEE_BPS = 100; // 1 %
    uint256 public constant MAX_OPTIONS = 20;
    uint256 private constant BINARY_SEARCH_ITERATIONS = 128;
    uint256 private constant SCALE = 1e18;

    // ──────────────  MARKET CONFIG  ──────────────
    uint256 public marketId;
    address public creator;
    address public resolver;
    string  public question;
    string  public categories;
    uint256 public endTime;
    uint256 public resolutionTime;
    uint256 public protocolFeeBps;
    uint256 public lpFeeBps;
    address public protocolFeeRecipient;
    bool    public isPrivate;
    uint256 public optionCount;
    string[] public optionLabels;

    // ──────────────  STATE  ──────────────
    bool    public resolved;
    bool    public invalid;
    uint256 public winningOption;

    // FPMM pool token inventories (one per option)
    uint256[] public poolBalances;

    // Total collateral. Invariant: for every i, pool[i] + totalOptionTokens[i] = collateral + virtualLiquidity
    uint256 public collateral;

    // Virtual liquidity (no real ETH backing — just for initial pricing)
    uint256 public virtualLiquidity;

    // User token balances: user → option → amount
    mapping(address => mapping(uint256 => uint256)) public tokens;
    uint256[] public totalOptionTokens; // tokens held by traders per option

    // LP state
    uint256 public totalLPShares;
    mapping(address => uint256) public lpShares;

    // Accumulated fees
    uint256 public accCreatorFees;
    uint256 public accProtocolFees;
    uint256 public accLPFees;
    uint256 public accVoterRewards;

    // ── Voter reward (decentralized resolution) ──
    address public votingContract;
    uint256 public voterRewardBps;   // % of protocol cut → voting contract (bps)

    // Participants
    mapping(address => bool) private _isPart;
    address[] public participants;

    // ──────────────  EVENTS  ──────────────
    event TokensBought(address indexed buyer, uint256 indexed option,
                       uint256 ethIn, uint256 tokensOut);
    event TokensSold(address indexed seller, uint256 indexed option,
                     uint256 tokensIn, uint256 ethOut);
    event LiquidityAdded(address indexed provider, uint256 ethAmount, uint256 lpSharesAmt);
    event LiquidityRemoved(address indexed provider, uint256 ethAmount, uint256 lpSharesAmt);
    event MarketResolved(uint256 indexed winOption, bool isInvalid, address resolvedBy);
    event TokensRedeemed(address indexed redeemer, uint256 amount);
    event FeesClaimed(address indexed to, uint256 amount, bool isCreator);

    // ──────────────  MODIFIERS  ──────────────
    modifier onlyCreatorOrResolver() {
        require(msg.sender == creator || msg.sender == resolver, "Not authorized");
        _;
    }
    modifier canResolve() {
        if (msg.sender == votingContract && votingContract != address(0)) {
            // Voting contract always authorized (decentralized resolution)
        } else if (isPrivate) {
            require(msg.sender == creator || msg.sender == resolver, "Not authorized");
        } else {
            require(msg.sender == resolver, "Public: only resolver");
        }
        _;
    }
    modifier marketOpen() {
        require(block.timestamp < endTime, "Market closed");
        require(!resolved, "Already resolved");
        _;
    }

    // ══════════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ══════════════════════════════════════════════════════════════

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
        uint256 _virtualLiquidity,
        bool _isPrivate,
        uint256 _lpFeeBps
    ) {
        require(_options.length >= 2 && _options.length <= MAX_OPTIONS, "2-20 options");
        require(_virtualLiquidity > 0, "Virtual liquidity > 0");
        require(_protocolFeeBps <= MAX_PROTOCOL_FEE_BPS, "Fee > 1%");

        marketId            = _marketId;
        creator             = _creator;
        resolver            = _resolver;
        question            = _question;
        endTime             = _endTime;
        resolutionTime      = _resolutionTime;
        protocolFeeBps      = _protocolFeeBps;
        lpFeeBps            = _lpFeeBps;
        protocolFeeRecipient= _protocolFeeRecipient;
        categories          = _categories;
        isPrivate           = _isPrivate;
        optionCount         = _options.length;

        virtualLiquidity = _virtualLiquidity;

        for (uint256 i = 0; i < _options.length; i++) {
            optionLabels.push(_options[i]);
            poolBalances.push(_virtualLiquidity);
            totalOptionTokens.push(0);
        }
    }

    // ══════════════════════════════════════════════════════════════
    //  FEES
    // ══════════════════════════════════════════════════════════════

    function setProtocolFeeBps(uint256 _newBps) external onlyCreatorOrResolver {
        require(_newBps <= MAX_PROTOCOL_FEE_BPS, "Exceeds 1%");
        protocolFeeBps = _newBps;
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

    function claimCreatorFees() external {
        require(msg.sender == creator, "Not creator");
        uint256 amt = accCreatorFees;
        require(amt > 0, "No fees");
        accCreatorFees = 0;
        _send(creator, amt);
        emit FeesClaimed(creator, amt, true);
    }

    function claimProtocolFees() external {
        require(msg.sender == protocolFeeRecipient || msg.sender == resolver, "Not auth");
        uint256 amt = accProtocolFees;
        require(amt > 0, "No fees");
        accProtocolFees = 0;
        _send(protocolFeeRecipient, amt);
        emit FeesClaimed(protocolFeeRecipient, amt, false);
    }

    /// @notice Send accumulated voter rewards to the resolution voting contract
    function claimVoterRewards() external {
        require(votingContract != address(0), "No voting contract");
        uint256 amt = accVoterRewards;
        require(amt > 0, "No voter rewards");
        accVoterRewards = 0;
        IVotingOracle(votingContract).depositVoterReward{value: amt}(marketId);
    }

    /// @notice Close betting and flush voter rewards — callable by anyone after endTime.
    function closeBetting() external {
        require(block.timestamp >= endTime, "Market still open");
        require(!resolved, "Already resolved");
        if (votingContract != address(0) && accVoterRewards > 0) {
            uint256 amt = accVoterRewards;
            accVoterRewards = 0;
            IVotingOracle(votingContract).depositVoterReward{value: amt}(marketId);
        }
    }

    function _takeFee(uint256 _amount) internal returns (uint256 net) {
        uint256 pFee = (_amount * protocolFeeBps) / 10000;
        uint256 lFee = (_amount * lpFeeBps)       / 10000;
        if (pFee > 0) {
            uint256 cCut = (pFee * 60) / 100;
            uint256 protocolCut = pFee - cCut;
            uint256 voterCut = (protocolCut * voterRewardBps) / 10000;
            accCreatorFees  += cCut;
            accVoterRewards += voterCut;
            accProtocolFees += protocolCut - voterCut;
        }
        accLPFees += lFee;
        net = _amount - pFee - lFee;
    }

    // ══════════════════════════════════════════════════════════════
    //  LIQUIDITY — mint-all-sides model
    // ══════════════════════════════════════════════════════════════

    function addLiquidity() external payable marketOpen returns (uint256 shares) {
        require(msg.value > 0, "Must send ETH");
        uint256 amt = msg.value;

        // Mint `amt` complete sets → add to every pool side
        collateral += amt;
        for (uint256 i = 0; i < optionCount; i++) {
            poolBalances[i] += amt;
        }

        if (totalLPShares == 0) {
            shares = amt;
        } else {
            shares = (totalLPShares * amt) / (collateral - amt);
        }

        lpShares[msg.sender] += shares;
        totalLPShares        += shares;
        emit LiquidityAdded(msg.sender, amt, shares);
    }

    function removeLiquidity(uint256 _shares) external returns (uint256 ethOut) {
        require(_shares > 0 && lpShares[msg.sender] >= _shares, "Bad shares");
        require(!resolved, "Already resolved");

        // Proportional token removal from each side
        uint256 minProp = type(uint256).max;
        for (uint256 i = 0; i < optionCount; i++) {
            uint256 prop = (poolBalances[i] * _shares) / totalLPShares;
            if (prop < minProp) minProp = prop;
        }

        // Merge minProp complete sets
        uint256 feeShare = (accLPFees * _shares) / totalLPShares;
        accLPFees -= feeShare;
        ethOut = minProp + feeShare;

        require(ethOut <= address(this).balance, "Insufficient balance");

        for (uint256 i = 0; i < optionCount; i++) {
            uint256 prop = (poolBalances[i] * _shares) / totalLPShares;
            poolBalances[i] -= prop;
        }
        collateral -= minProp;

        lpShares[msg.sender] -= _shares;
        totalLPShares        -= _shares;

        _send(msg.sender, ethOut);
        emit LiquidityRemoved(msg.sender, ethOut, _shares);
    }

    function withdrawLP() external {
        require(resolved, "Not resolved");
        uint256 s = lpShares[msg.sender];
        require(s > 0, "No LP shares");

        uint256 poolVal = _lpPoolValue();
        uint256 ethOut  = (poolVal * s) / totalLPShares;
        if (ethOut > address(this).balance) ethOut = address(this).balance;

        lpShares[msg.sender] = 0;
        totalLPShares -= s;

        if (ethOut > 0) _send(msg.sender, ethOut);
        emit LiquidityRemoved(msg.sender, ethOut, s);
    }

    // ══════════════════════════════════════════════════════════════
    //  BUY — mint complete sets, swap complement into pool
    //
    //  Math (overflow-safe chain multiplication):
    //    1. Save q_orig[i] for all i
    //    2. Mint amtIn sets: q[i] += amtIn for all i
    //    3. Compute q[X]_final via invariant:
    //       q[X]_final = q[X]_orig * ∏_{i≠X}( q[i]_orig / q[i]_new )
    //       (chain multiply-then-divide keeps intermediate bounded)
    //    4. tokensOut = q[X]_new − q[X]_final
    // ══════════════════════════════════════════════════════════════

    function buy(uint256 _option) external payable marketOpen returns (uint256 tokensOut) {
        require(msg.value > 0, "Must send ETH");
        require(_option < optionCount, "Invalid option");
        _trackPart();

        uint256 amtIn = _takeFee(msg.value);
        require(amtIn > 0, "Fee eats all");

        // Save original pool balances
        uint256[] memory orig = new uint256[](optionCount);
        for (uint256 i = 0; i < optionCount; i++) {
            orig[i] = poolBalances[i];
        }

        // Mint amtIn complete sets
        collateral += amtIn;
        for (uint256 i = 0; i < optionCount; i++) {
            poolBalances[i] += amtIn;
        }

        // Chain multiplication: q[X]_final = q[X]_orig * ∏_{i≠X}(q[i]_orig / q[i]_new)
        uint256 qFinal = orig[_option];
        for (uint256 i = 0; i < optionCount; i++) {
            if (i == _option) continue;
            // Multiply by orig[i], then divide by poolBalances[i]
            // This keeps the intermediate value bounded
            qFinal = (qFinal * orig[i]) / poolBalances[i];
        }

        // Cap: pool must never drop below virtual liquidity
        // This ensures totalOptionTokens[_option] can never exceed real collateral
        if (qFinal < virtualLiquidity) qFinal = virtualLiquidity;

        tokensOut = poolBalances[_option] - qFinal;
        require(tokensOut > 0, "Amount too small");
        poolBalances[_option] = qFinal;

        tokens[msg.sender][_option] += tokensOut;
        totalOptionTokens[_option]  += tokensOut;

        emit TokensBought(msg.sender, _option, msg.value, tokensOut);
    }

    // ══════════════════════════════════════════════════════════════
    //  SELL — return tokens, merge excess complete sets, release ETH
    //
    //  For N>2 the polynomial ∏(q[i] - R) = k has no closed form,
    //  so we use binary search (128 iterations → 1 wei precision).
    //
    //  Overflow-safe check: compare ∏((q_after[i]-R) / q_before[i])
    //  against 1.0 using scaled arithmetic.
    // ══════════════════════════════════════════════════════════════

    function sell(uint256 _option, uint256 _tokensIn) external marketOpen returns (uint256 ethOut) {
        require(_tokensIn > 0, "Amount 0");
        require(_option < optionCount, "Invalid option");
        require(tokens[msg.sender][_option] >= _tokensIn, "Not enough tokens");

        // Save pool state BEFORE adding sold tokens (this is our "k reference")
        uint256[] memory qBefore = new uint256[](optionCount);
        for (uint256 i = 0; i < optionCount; i++) {
            qBefore[i] = poolBalances[i];
        }

        // Return tokens to pool
        poolBalances[_option] += _tokensIn;

        // Binary search for R such that ∏(poolBalances[i] - R) ≈ ∏(qBefore[i])
        uint256 lo = 0;
        uint256 hi = _minPool(); // R can't exceed the smallest pool balance
        uint256 mid;

        for (uint256 it = 0; it < BINARY_SEARCH_ITERATIONS; it++) {
            mid = (lo + hi + 1) / 2;
            if (mid == 0) break;
            if (_productCompare(mid, qBefore)) {
                lo = mid; // ∏(q-mid)/∏(qBefore) >= 1 → R could be bigger
            } else {
                hi = mid - 1;
            }
        }
        uint256 grossOut = lo;

        require(grossOut > 0, "Sell too small");
        require(grossOut <= collateral, "Exceeds collateral");

        // Merge grossOut complete sets
        for (uint256 i = 0; i < optionCount; i++) {
            poolBalances[i] -= grossOut;
        }
        collateral -= grossOut;

        // Burn user tokens
        tokens[msg.sender][_option] -= _tokensIn;
        totalOptionTokens[_option]  -= _tokensIn;

        // Deduct sell-side fees
        uint256 pFee = (grossOut * protocolFeeBps) / 10000;
        uint256 lFee = (grossOut * lpFeeBps)       / 10000;
        ethOut = grossOut - pFee - lFee;

        if (pFee > 0) {
            uint256 cCut = (pFee * 60) / 100;
            accCreatorFees  += cCut;
            accProtocolFees += pFee - cCut;
        }
        accLPFees += lFee;

        require(ethOut > 0, "Fee eats all");
        require(ethOut <= address(this).balance, "Insufficient ETH");

        emit TokensSold(msg.sender, _option, _tokensIn, ethOut);
        _send(msg.sender, ethOut);
    }

    // ══════════════════════════════════════════════════════════════
    //  RESOLUTION & REDEMPTION
    // ══════════════════════════════════════════════════════════════

    function resolve(uint256 _winOption, bool _invalid) external canResolve {
        require(!resolved, "Already resolved");
        require(block.timestamp >= endTime, "Market still open");
        if (!_invalid) {
            require(_winOption < optionCount, "Invalid option");
        }

        winningOption = _winOption;
        invalid       = _invalid;
        resolved      = true;
        emit MarketResolved(_winOption, _invalid, msg.sender);
    }

    function emergencyResolve() external {
        require(!resolved, "Already resolved");
        require(
            votingContract != address(0) &&
            IVotingOracle(votingContract).canEmergencyResolve(marketId),
            "Emergency resolve not available"
        );
        invalid  = true;
        resolved = true;
        emit MarketResolved(0, true, msg.sender);
    }

    function redeem() external {
        require(resolved, "Not resolved");
        uint256 payout;

        if (invalid) {
            // Pro-rata refund across all tokens user holds
            uint256 userTotal;
            uint256 allTokens;
            for (uint256 i = 0; i < optionCount; i++) {
                userTotal += tokens[msg.sender][i];
                allTokens += totalOptionTokens[i];
            }
            require(userTotal > 0, "No tokens");
            payout = allTokens > 0 ? (collateral * userTotal) / allTokens : 0;
            for (uint256 i = 0; i < optionCount; i++) {
                totalOptionTokens[i] -= tokens[msg.sender][i];
                tokens[msg.sender][i] = 0;
            }
        } else {
            payout = tokens[msg.sender][winningOption];
            require(payout > 0, "No winning tokens");
            totalOptionTokens[winningOption] -= payout;
            tokens[msg.sender][winningOption] = 0;
        }

        collateral -= payout;

        // Safety cap — should NEVER trigger with FPMM
        if (payout > address(this).balance) payout = address(this).balance;

        if (payout > 0) _send(msg.sender, payout);
        emit TokensRedeemed(msg.sender, payout);
    }

    // ══════════════════════════════════════════════════════════════
    //  VIEWS
    // ══════════════════════════════════════════════════════════════

    function getPrice(uint256 _option) public view returns (uint256) {
        require(_option < optionCount, "Invalid option");
        uint256 sumInverse;
        // Price of option X = ∏_{i≠X}(pool[i]) / Σ_j(∏_{i≠j}(pool[i]))
        // Simplified: price ∝ 1/pool[X], normalized
        // Use inverse-reserve weighting (same as N-outcome CPMM):
        //   price[X] = (1/pool[X]) / Σ(1/pool[i])  → scaled to 10000
        for (uint256 i = 0; i < optionCount; i++) {
            sumInverse += SCALE / poolBalances[i]; // 1/pool[i] scaled
        }
        return ((SCALE / poolBalances[_option]) * 10000) / sumInverse;
    }

    function getOdds() external view returns (uint256[] memory odds) {
        odds = new uint256[](optionCount);
        uint256 sumInverse;
        for (uint256 i = 0; i < optionCount; i++) {
            sumInverse += SCALE / poolBalances[i];
        }
        for (uint256 i = 0; i < optionCount; i++) {
            odds[i] = ((SCALE / poolBalances[i]) * 10000) / sumInverse;
        }
    }

    function getMarketInfo() external view returns (
        string memory _question,
        uint256 _endTime,
        uint256 _optionCount,
        uint256 _contractBalance,
        uint256 _winningOption,
        bool _resolved,
        bool _invalid,
        address _creator
    ) {
        return (question, endTime, optionCount, address(this).balance,
                winningOption, resolved, invalid, creator);
    }

    function getPoolBalances() external view returns (uint256[] memory) {
        return poolBalances;
    }

    function getTotalOptionTokens() external view returns (uint256[] memory) {
        return totalOptionTokens;
    }

    function getOptionLabels() external view returns (string[] memory) {
        return optionLabels;
    }

    function getLPInfo() external view returns (
        uint256 _totalLPShares,
        uint256 _totalLPValue,
        uint256 _lpFeeBps,
        uint256 _collateral
    ) {
        return (totalLPShares, _lpPoolValue(), lpFeeBps, collateral);
    }

    function getLPPosition(address _user) external view returns (uint256 shares, uint256 value) {
        shares = lpShares[_user];
        if (totalLPShares > 0 && shares > 0) {
            value = (_lpPoolValue() * shares) / totalLPShares;
        }
    }

    function getPosition(address _user) external view returns (uint256[] memory amounts) {
        amounts = new uint256[](optionCount);
        for (uint256 i = 0; i < optionCount; i++) {
            amounts[i] = tokens[_user][i];
        }
    }

    function getFeeInfo() external view returns (
        uint256 _protocolFeeBps,
        uint256 _lpFeeBps,
        uint256 _accCreatorFees,
        uint256 _accProtocolFees,
        uint256 _maxProtocolFeeBps
    ) {
        return (protocolFeeBps, lpFeeBps, accCreatorFees, accProtocolFees, MAX_PROTOCOL_FEE_BPS);
    }

    function getParticipantCount() external view returns (uint256) {
        return participants.length;
    }

    // ══════════════════════════════════════════════════════════════
    //  INTERNAL HELPERS
    // ══════════════════════════════════════════════════════════════

    /**
     * @dev Check if ∏(poolBalances[i] − R) >= ∏(qBefore[i]).
     *      Uses chain division to stay within uint256:
     *        ratio = ∏( (pool[i]−R) / qBefore[i] ), if ratio >= 1.0 → true
     */
    function _productCompare(uint256 R, uint256[] memory qBefore) internal view returns (bool) {
        uint256 ratio = SCALE; // 1.0 scaled
        for (uint256 i = 0; i < optionCount; i++) {
            if (poolBalances[i] < R) return false; // can't subtract
            ratio = (ratio * (poolBalances[i] - R)) / qBefore[i];
            if (ratio == 0) return false;
        }
        return ratio >= SCALE;
    }

    /// @dev Smallest pool balance (max possible R)
    function _minPool() internal view returns (uint256 m) {
        m = poolBalances[0];
        for (uint256 i = 1; i < optionCount; i++) {
            if (poolBalances[i] < m) m = poolBalances[i];
        }
    }

    function _lpPoolValue() internal view returns (uint256) {
        uint256 traderClaim;
        if (resolved && !invalid) {
            traderClaim = totalOptionTokens[winningOption]; // only winning tokens redeem
        } else {
            traderClaim = collateral; // pre-resolution or INVALID: worst-case reserve
        }
        uint256 unclaimedFees = accCreatorFees + accProtocolFees + accVoterRewards;
        uint256 bal = address(this).balance;
        if (bal <= traderClaim + unclaimedFees) return 0;
        return bal - traderClaim - unclaimedFees;
    }

    function _trackPart() internal {
        if (!_isPart[msg.sender]) {
            participants.push(msg.sender);
            _isPart[msg.sender] = true;
        }
    }

    function _send(address _to, uint256 _amt) internal {
        (bool ok, ) = _to.call{value: _amt}("");
        require(ok, "ETH transfer failed");
    }

    receive() external payable {}
}
