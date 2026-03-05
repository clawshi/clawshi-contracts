// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title CTFMarket — Conditional Token Framework + FPMM
 * @notice Binary YES/NO prediction market with GUARANTEED payouts.
 *
 *  Uses the Fixed Product Market Maker (FPMM) pattern:
 *    - AMM holds inventories of YES and NO tokens
 *    - Buy:  ETH → mint complete sets → sell complement into AMM
 *    - Sell: Return tokens to AMM → merge excess sets → release ETH
 *    - Collateral is LOCKED and only released via set-merging
 *    - Draining the pool via sells is IMPOSSIBLE by design
 *
 *  Settlement: 1 winning token = exactly 1 ETH (guaranteed by collateral)
 *
 *  Fee structure (per-trade):
 *    - Protocol fee: max 1 % → 60 % creator, 40 % protocol
 *    - LP fee: configurable → stays in pool
 */
import "./IVotingOracle.sol";

contract CTFMarket {

    // ──────────────  TYPES  ──────────────
    enum Outcome { UNRESOLVED, YES, NO, INVALID }

    // ──────────────  CONSTANTS  ──────────────
    uint256 public constant MAX_PROTOCOL_FEE_BPS = 100; // 1 %

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

    // ──────────────  STATE  ──────────────
    Outcome public outcome;
    bool    public resolved;

    // FPMM pool token inventories
    uint256 public poolYes;
    uint256 public poolNo;

    // Total collateral backing all tokens in existence
    // Invariant: collateral == poolYes + totalYesTokens == poolNo + totalNoTokens
    uint256 public collateral;

    // User token balances
    mapping(address => uint256) public yesTokens;
    mapping(address => uint256) public noTokens;
    uint256 public totalYesTokens;   // tokens held by traders
    uint256 public totalNoTokens;

    // Virtual liquidity (no real ETH backing — just for initial pricing)
    uint256 public virtualLiquidity;

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
    uint256 public voterRewardBps;   // % of protocol cut → voting contract (bps, 1000 = 10%)

    // Participants
    mapping(address => bool) private _isPart;
    address[] public participants;

    // ──────────────  EVENTS  ──────────────
    event TokensBought(address indexed buyer, bool isYes, uint256 ethIn,
                       uint256 tokensOut, uint256 newPoolYes, uint256 newPoolNo);
    event TokensSold(address indexed seller, bool isYes, uint256 tokensIn,
                     uint256 ethOut, uint256 newPoolYes, uint256 newPoolNo);
    event LiquidityAdded(address indexed provider, uint256 ethAmount,
                         uint256 shares, uint256 newPoolYes, uint256 newPoolNo);
    event LiquidityRemoved(address indexed provider, uint256 ethAmount,
                           uint256 shares, uint256 newPoolYes, uint256 newPoolNo);
    event MarketResolved(Outcome outcome, address resolvedBy);
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
        uint256 _endTime,
        uint256 _resolutionTime,
        uint256 _protocolFeeBps,
        address _protocolFeeRecipient,
        string memory _categories,
        uint256 _virtualLiquidity,
        bool _isPrivate,
        uint256 _lpFeeBps
    ) {
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

        // Virtual seed — provides initial pricing without real ETH
        virtualLiquidity = _virtualLiquidity;
        poolYes = _virtualLiquidity;
        poolNo  = _virtualLiquidity;
        // collateral stays 0 until someone adds real liquidity/buys
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
    ///         This is a convenience function; the voting contract also auto-checks endTime.
    function closeBetting() external {
        require(block.timestamp >= endTime, "Market still open");
        require(!resolved, "Already resolved");
        // Flush any accumulated voter rewards to voting contract
        if (votingContract != address(0) && accVoterRewards > 0) {
            uint256 amt = accVoterRewards;
            accVoterRewards = 0;
            IVotingOracle(votingContract).depositVoterReward{value: amt}(marketId);
        }
    }

    function _takeFee(uint256 _amount) internal returns (uint256 net) {
        uint256 pFee  = (_amount * protocolFeeBps) / 10000;
        uint256 lFee  = (_amount * lpFeeBps)       / 10000;
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
    //  LIQUIDITY — mint-both-sides model
    // ══════════════════════════════════════════════════════════════

    /**
     * @notice Add liquidity. Mints equal YES+NO tokens and adds to pool.
     *         LP shares are proportional to the increase in pool depth.
     */
    function addLiquidity() external payable marketOpen returns (uint256 shares) {
        require(msg.value > 0, "Must send ETH");
        uint256 amt = msg.value;

        // Mint `amt` complete sets and deposit both into pool
        collateral += amt;
        poolYes    += amt;
        poolNo     += amt;

        if (totalLPShares == 0) {
            shares = amt;
        } else {
            // Proportional to existing collateral that backs the pool
            // poolCollateral = collateral before this deposit = collateral - amt
            shares = (totalLPShares * amt) / (collateral - amt);
        }

        lpShares[msg.sender] += shares;
        totalLPShares        += shares;

        emit LiquidityAdded(msg.sender, amt, shares, poolYes, poolNo);
    }

    /**
     * @notice Remove liquidity (pre-resolution only).
     *         Removes proportional tokens from pool, merges complete sets,
     *         returns ETH. Imbalanced tokens = impermanent loss.
     */
    function removeLiquidity(uint256 _shares) external returns (uint256 ethOut) {
        require(_shares > 0 && lpShares[msg.sender] >= _shares, "Bad shares");
        require(!resolved, "Already resolved");

        uint256 propYes = (poolYes * _shares) / totalLPShares;
        uint256 propNo  = (poolNo  * _shares) / totalLPShares;
        uint256 merged  = propYes < propNo ? propYes : propNo;

        // LP fee share
        uint256 feeShare = (accLPFees * _shares) / totalLPShares;
        accLPFees -= feeShare;

        ethOut = merged + feeShare;
        require(ethOut <= address(this).balance, "Insufficient balance");

        poolYes    -= propYes;
        poolNo     -= propNo;
        collateral -= merged;

        lpShares[msg.sender] -= _shares;
        totalLPShares        -= _shares;

        _send(msg.sender, ethOut);
        emit LiquidityRemoved(msg.sender, ethOut, _shares, poolYes, poolNo);
    }

    /**
     * @notice Withdraw LP after resolution. Gets remaining ETH
     *         (residual collateral from pool tokens + fees).
     */
    function withdrawLP() external {
        require(resolved, "Not resolved");
        uint256 s = lpShares[msg.sender];
        require(s > 0, "No LP shares");

        // Pool's remaining value after resolution
        uint256 poolValue = _lpPoolValue();
        uint256 ethOut = (poolValue * s) / totalLPShares;
        if (ethOut > address(this).balance) ethOut = address(this).balance;

        lpShares[msg.sender] = 0;
        totalLPShares -= s;

        if (ethOut > 0) _send(msg.sender, ethOut);
        emit LiquidityRemoved(msg.sender, ethOut, s, poolYes, poolNo);
    }

    // ══════════════════════════════════════════════════════════════
    //  BUY — mint complete sets, swap complement into pool
    // ══════════════════════════════════════════════════════════════

    /**
     * @notice Buy YES or NO tokens for ETH.
     * @param _buyYes  true = buy YES, false = buy NO
     *
     * Math:
     *   1. Mint `amtIn` complete sets      →  adds amtIn YES+NO to pool
     *   2. Constant‑product invariant k = poolYes_old * poolNo_old
     *   3. After adding amtIn to both sides:
     *        keep complement side at (q + amtIn), adjust desired side:
     *        q_desired_new = k / (q_complement + amtIn)
     *   4. tokensOut = q_desired_old + amtIn − q_desired_new
     */
    function buy(bool _buyYes) external payable marketOpen returns (uint256 tokensOut) {
        require(msg.value > 0, "Must send ETH");
        _trackPart();

        uint256 amtIn = _takeFee(msg.value);
        require(amtIn > 0, "Fee eats all");

        // Constant product BEFORE minting
        uint256 k = poolYes * poolNo;

        // Mint amtIn complete sets
        collateral += amtIn;
        poolYes    += amtIn;
        poolNo     += amtIn;

        if (_buyYes) {
            uint256 newPoolYes = k / poolNo;   // keep poolNo, shrink poolYes
            // Cap: pool must never drop below virtual liquidity
            // This ensures totalYesTokens can never exceed real collateral
            if (newPoolYes < virtualLiquidity) newPoolYes = virtualLiquidity;
            tokensOut = poolYes - newPoolYes;
            poolYes   = newPoolYes;
            yesTokens[msg.sender] += tokensOut;
            totalYesTokens        += tokensOut;
        } else {
            uint256 newPoolNo = k / poolYes;
            if (newPoolNo < virtualLiquidity) newPoolNo = virtualLiquidity;
            tokensOut = poolNo - newPoolNo;
            poolNo    = newPoolNo;
            noTokens[msg.sender] += tokensOut;
            totalNoTokens        += tokensOut;
        }

        require(tokensOut > 0, "Amount too small");
        emit TokensBought(msg.sender, _buyYes, msg.value, tokensOut, poolYes, poolNo);
    }

    // ══════════════════════════════════════════════════════════════
    //  SELL — return tokens, merge excess sets, release ETH
    //  ETH only exits via set-merging → pool can NEVER be drained
    // ══════════════════════════════════════════════════════════════

    /**
     * @notice Sell outcome tokens for ETH.
     *
     * Math:
     *   1. Add tokensIn to the sold side's pool balance
     *   2. Now pool has surplus of both tokens.
     *      Find R (returnAmount) such that:
     *        (poolYes − R) × (poolNo − R) = k       [constant product]
     *      Quadratic:  R² − (pY+pN)R + (pY·pN − k) = 0
     *      Discriminant = (pY−pN)² + 4k   (always > 0)
     *      R = [ (pY+pN) − √disc ] / 2    (take smaller root)
     *   3. Merge R complete sets → release R ETH from collateral
     */
    function sell(bool _sellYes, uint256 _tokensIn) external marketOpen returns (uint256 ethOut) {
        require(_tokensIn > 0, "Amount 0");
        if (_sellYes) {
            require(yesTokens[msg.sender] >= _tokensIn, "Not enough YES");
        } else {
            require(noTokens[msg.sender] >= _tokensIn, "Not enough NO");
        }

        // k BEFORE adding sold tokens
        uint256 k = poolYes * poolNo;

        // Step 1 — return tokens to pool
        if (_sellYes) {
            poolYes += _tokensIn;
        } else {
            poolNo += _tokensIn;
        }

        // Step 2 — solve quadratic for R
        uint256 sum  = poolYes + poolNo;
        uint256 prod = poolYes * poolNo;
        uint256 disc = sum * sum - 4 * (prod - k); // = (pY-pN)^2 + 4k
        uint256 sqrtD = _sqrt(disc);
        uint256 grossOut = (sum - sqrtD) / 2;

        require(grossOut > 0, "Sell too small");
        require(grossOut <= collateral, "Exceeds collateral");

        // Step 3 — merge grossOut complete sets
        poolYes    -= grossOut;
        poolNo     -= grossOut;
        collateral -= grossOut;

        // Burn user tokens
        if (_sellYes) {
            yesTokens[msg.sender] -= _tokensIn;
            totalYesTokens        -= _tokensIn;
        } else {
            noTokens[msg.sender] -= _tokensIn;
            totalNoTokens        -= _tokensIn;
        }

        // Deduct sell-side fees from grossOut
        uint256 pFee = (grossOut * protocolFeeBps) / 10000;
        uint256 lFee = (grossOut * lpFeeBps)       / 10000;
        ethOut = grossOut - pFee - lFee;

        if (pFee > 0) {
            uint256 cCut = (pFee * 60) / 100;
            accCreatorFees  += cCut;
            accProtocolFees += pFee - cCut;
        }
        accLPFees += lFee;
        // fees remain in contract — just tracked
        // collateral was already reduced; fee ETH stays in contract balance

        require(ethOut > 0, "Fee eats all");
        require(ethOut <= address(this).balance, "Insufficient ETH");

        emit TokensSold(msg.sender, _sellYes, _tokensIn, ethOut, poolYes, poolNo);
        _send(msg.sender, ethOut);
    }

    // ══════════════════════════════════════════════════════════════
    //  RESOLUTION & REDEMPTION
    // ══════════════════════════════════════════════════════════════

    function resolve(Outcome _outcome) external canResolve {
        require(!resolved, "Already resolved");
        require(block.timestamp >= endTime, "Market still open");
        require(_outcome == Outcome.YES || _outcome == Outcome.NO
                || _outcome == Outcome.INVALID, "Bad outcome");

        outcome  = _outcome;
        resolved = true;
        emit MarketResolved(_outcome, msg.sender);
    }

    function emergencyResolve() external {
        require(!resolved, "Already resolved");
        require(
            votingContract != address(0) &&
            IVotingOracle(votingContract).canEmergencyResolve(marketId),
            "Emergency resolve not available"
        );
        outcome  = Outcome.INVALID;
        resolved = true;
        emit MarketResolved(Outcome.INVALID, msg.sender);
    }

    /**
     * @notice Redeem winning tokens for ETH.
     *  YES wins → 1 YES = 1 ETH  (guaranteed by collateral)
     *  NO  wins → 1 NO  = 1 ETH
     *  INVALID  → pro-rata refund from collateral
     */
    function redeem() external {
        require(resolved, "Not resolved");
        uint256 payout;

        if (outcome == Outcome.INVALID) {
            uint256 userTotal = yesTokens[msg.sender] + noTokens[msg.sender];
            uint256 allTokens = totalYesTokens + totalNoTokens;
            require(userTotal > 0, "No tokens");
            payout = allTokens > 0 ? (collateral * userTotal) / allTokens : 0;
            totalYesTokens -= yesTokens[msg.sender];
            totalNoTokens  -= noTokens[msg.sender];
            yesTokens[msg.sender] = 0;
            noTokens[msg.sender]  = 0;
        } else if (outcome == Outcome.YES) {
            payout = yesTokens[msg.sender];
            require(payout > 0, "No winning tokens");
            totalYesTokens -= payout;
            yesTokens[msg.sender] = 0;
        } else {
            payout = noTokens[msg.sender];
            require(payout > 0, "No winning tokens");
            totalNoTokens -= payout;
            noTokens[msg.sender] = 0;
        }

        collateral -= payout;

        // Safety cap — should NEVER trigger with FPMM invariant
        if (payout > address(this).balance) payout = address(this).balance;

        if (payout > 0) _send(msg.sender, payout);
        emit TokensRedeemed(msg.sender, payout);
    }

    // ══════════════════════════════════════════════════════════════
    //  VIEWS
    // ══════════════════════════════════════════════════════════════

    function yesPrice() public view returns (uint256) {
        return (poolNo * 10000) / (poolYes + poolNo);
    }
    function noPrice() public view returns (uint256) {
        return (poolYes * 10000) / (poolYes + poolNo);
    }
    function getOdds() external view returns (uint256 yesOdds, uint256 noOdds) {
        return (yesPrice(), noPrice());
    }

    function getMarketInfo() external view returns (
        string memory _question,
        uint256 _endTime,
        uint256 _vYes,
        uint256 _vNo,
        uint256 _totalYesTokens,
        uint256 _totalNoTokens,
        uint256 _contractBalance,
        Outcome _outcome,
        bool _resolved,
        address _creator
    ) {
        return (question, endTime, poolYes, poolNo, totalYesTokens, totalNoTokens,
                address(this).balance, outcome, resolved, creator);
    }

    function getLPInfo() external view returns (
        uint256 _totalLPShares,
        uint256 _totalLPValue,
        uint256 _lpFeeBps,
        uint256 _tradingPool
    ) {
        return (totalLPShares, _lpPoolValue(), lpFeeBps, collateral);
    }

    function getLPPosition(address _user) external view returns (uint256 shares, uint256 value) {
        shares = lpShares[_user];
        if (totalLPShares > 0 && shares > 0) {
            value = (_lpPoolValue() * shares) / totalLPShares;
        }
    }

    function getPosition(address _user) external view returns (uint256 yes, uint256 no) {
        return (yesTokens[_user], noTokens[_user]);
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
    //  INTERNAL
    // ══════════════════════════════════════════════════════════════

    /**
     * @dev LP pool value = remaining contract ETH after accounting for:
     *      trader collateral (needed for redemptions) + unclaimed fees.
     *      After resolution includes surplus collateral from pool tokens.
     */
    function _lpPoolValue() internal view returns (uint256) {
        uint256 traderClaim;
        if (resolved) {
            if (outcome == Outcome.YES) {
                traderClaim = totalYesTokens; // only winning tokens can redeem
            } else if (outcome == Outcome.NO) {
                traderClaim = totalNoTokens;
            } else {
                traderClaim = collateral; // INVALID: pro-rata from all collateral
            }
        } else {
            traderClaim = collateral; // pre-resolution: worst-case reserve
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

    /// @dev Babylonian integer square root
    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        y = x;
        uint256 z = (x + 1) / 2;
        while (z < y) { y = z; z = (x / z + z) / 2; }
    }

    receive() external payable {}
}
