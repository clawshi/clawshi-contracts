// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./IClawshiFactory.sol";
import "./IVotingOracle.sol";

/**
 * @title ArenaMarket — Elimination Prediction Market with Internal AMM (v2)
 * @notice N tokens enter, one survives. Each option gets its own constant-product
 *         (x*y=k) pool inside a single contract.
 *
 *  Trading: Uniswap-style router entrypoints with slippage + deadline.
 *  Reap:    announce → delay → execute (MEV-protected). Threshold-signer path via EIP-712.
 *  Settle:  Winner declared. Settlement pool distributed pro-rata to winner-token holders.
 *
 *  v2 Hardening:
 *   - Pull-based withdrawals for ALL ETH outflows
 *   - ReentrancyGuard on all state-mutating externals
 *   - Explicit market phases (Open/Frozen/Settled/Cancelled)
 *   - Split access control (onlyAdmin vs onlyResolutionAuthority)
 *   - Swap + Sync events for DEX analytics
 *   - Signature array capped + low-s enforcement
 *   - Solvency invariant (computed sum, no cached tracker)
 *   - Custom errors for gas efficiency
 */
contract ArenaMarket {

    // ══════════════════════════════════════════════════════════════
    //  CUSTOM ERRORS
    // ══════════════════════════════════════════════════════════════

    error InvalidOptionCount();
    error EndMustBeFuture();
    error FeeTooHigh();
    error InsufficientSeed();
    error InvalidOption();
    error OptionEliminated();
    error ZeroAmount();
    error AgentsOnly();
    error MarketNotOpen();
    error MarketNotSettled();
    error MarketAlreadyClosed();
    error AlreadyClaimed();
    error NotAdmin();
    error NotResolutionAuthority();
    error DeadlineExpired();
    error SlippageExceeded();
    error InsufficientBalance();
    error TransferFailed();
    error NoRewardsToClaim();
    error NoVotingContract();
    error ReapAlreadyPending();
    error NoReapPending();
    error ReapDelayNotPassed();
    error CannotReapLast();
    error AlreadyEliminated();
    error WinnerEliminated();
    error NotYetEnded();
    error AlreadyFrozenOrClosed();
    error ZeroAddress();
    error AlreadyReporter();
    error NotReporter();
    error InvalidThreshold();
    error WrongMarket();
    error InvalidNonce();
    error TooEarly();
    error AuthExpired();
    error AliveCountMismatch();
    error ThresholdNotSet();
    error NotEnoughSignatures();
    error TooManySignatures();
    error SigsNotSorted();
    error InvalidSignature();
    error VoterRewardTooHigh();
    error NothingToWithdraw();
    error NothingToSweep();
    error NotCreator();
    error Reentrancy();
    error DirectETHNotAllowed();
    error SweepTooEarly();
    error NotClosedYet();
    error TradingClosed();
    error WinnerSupplyMismatch();
    error MaxWalletExceeded();
    error BelowVirtualFloor();

    // ══════════════════════════════════════════════════════════════
    //  CONSTANTS
    // ══════════════════════════════════════════════════════════════

    uint256 public constant INIT_TOKENS = 1_000_000e18;
    uint256 public constant REAP_DELAY = 60;
    uint256 public constant MAX_SIGS = 32;
    uint256 public constant MIN_OPTIONS = 8;
    uint256 public constant PRIZE_POT_THRESHOLD = 3; // last 3 reaps → prize pot instead of LP
    uint256 public constant SURGE_BASE_BPS = 100; // 1% — threshold for surge fee split

    // ── Max Wallet ──────────────────────────────────────────────
    uint256 public constant MAX_WALLET_REAP_BOOST_BPS = 100;   // +1% per reap completed
    uint256 public constant MAX_WALLET_LP_SCALE_BPS   = 50;    // +0.5% per 1 ETH real liquidity
    uint256 public constant MAX_WALLET_LP_CAP_BPS     = 500;   // LP boost capped at 5%
    uint256 public constant MAX_WALLET_HARD_CAP_BPS   = 1500;  // 15% hard cap

    /// @dev secp256k1 half-order for low-s signature enforcement
    uint256 private constant _HALF_ORDER =
        0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    // ══════════════════════════════════════════════════════════════
    //  ENUMS
    // ══════════════════════════════════════════════════════════════

    enum Phase { Open, Frozen, Settled, Cancelled }

    // ══════════════════════════════════════════════════════════════
    //  STATE
    // ══════════════════════════════════════════════════════════════

    // ── Reentrancy guard ────────────────────────────────────────
    uint256 private _locked = 1;

    // ── Identity ────────────────────────────────────────────────
    uint256 public marketId;
    address public creator;
    address public resolver;
    address public factory;
    string  public question;
    string  public categories;
    uint256 public endTime;
    uint256 public protocolFeeBps;
    address public protocolFeeRecipient;
    bool    public agentOnly;

    // ── Phase ───────────────────────────────────────────────────
    Phase public phase;

    // ── Options ─────────────────────────────────────────────────
    uint256 public optionCount;
    string[] public optionLabels;

    // ── Per-pool AMM state ──────────────────────────────────────
    uint256[] public tokenReserve;
    uint256[] public ethReserve;
    bool[]    public eliminated;
    uint256   public aliveCount;

    // ── Virtual liquidity seed (purely synthetic, never backed by real ETH) ──
    // INVARIANT: ethReserve[i] must NEVER drop below this value via sells
    //            or any outflow.  Only settle() and reap() may zero a pool,
    //            and both exclude the virtual portion from distributions.
    uint256 public virtualEthPerPool;

    // ── Max wallet (anti-dominance) ─────────────────────────────
    uint256 public maxWalletBaseBps;  // 0 = disabled, 100 = 1% start

    // ── User balances ───────────────────────────────────────────
    mapping(address => mapping(uint256 => uint256)) public balances;
    mapping(address => bool) private _isPart;
    address[] public participants;

    // ── Pull-based withdrawals ──────────────────────────────────
    mapping(address => uint256) public pendingWithdrawal;
    uint256 public totalPendingWithdrawals;

    // ── Accumulated fees ────────────────────────────────────────
    uint256 public accCreatorFees;
    uint256 public accProtocolFees;
    uint256 public accReporterRewards;

    // ── Settlement ──────────────────────────────────────────────
    uint256 public winnerIndex;
    uint256 public settlementPool;
    uint256 public winnerCirculatingAtSettle;
    mapping(address => bool) public claimedSettlement;

    // ── UMA resolution oracle ───────────────────────────────────
    address public votingContract;
    uint256 public voterRewardBps;
    uint256 public accVoterRewards;

    // ── Settlement timing ───────────────────────────────────────
    uint256 public settleTime; // timestamp when settled/cancelled (for sweep delay)
    uint256 public constant SWEEP_DELAY = 30 days;

    // ── MEV-protected reap ──────────────────────────────────────
    struct PendingReap {
        uint256 loserIndex;
        uint256 announceTime;
        bool    active;
    }
    PendingReap public pendingReap;

    // ── Reap weight snapshot (front-run protection) ─────────────
    uint256[] public reapWeightSnapshot;

    // ── Threshold-signer reap (EIP-712) ─────────────────────────
    mapping(address => bool) public reporters;
    uint256 public reporterCount;
    uint256 public threshold;
    uint256 public reapNonce;
    bytes32 public DOMAIN_SEPARATOR;

    bytes32 public constant REAP_AUTHORIZATION_TYPEHASH = keccak256(
        "ReapAuthorization(uint256 marketId,uint256 loserIndex,uint256 expectedAliveCount,uint256 nonce,uint256 validAfter,uint256 validBefore,bytes32 evidenceHash)"
    );

    struct ReapAuthorization {
        uint256 marketId;
        uint256 loserIndex;
        uint256 expectedAliveCount;
        uint256 nonce;
        uint256 validAfter;
        uint256 validBefore;
        bytes32 evidenceHash;
    }

    // ══════════════════════════════════════════════════════════════
    //  EVENTS
    // ══════════════════════════════════════════════════════════════

    // DEX-style
    event Swap(address indexed sender, uint256 indexed option, bool exactIn, bool buySide, uint256 amountIn, uint256 amountOut, uint256 fee);
    event Sync(uint256 indexed option, uint256 tokenReserve, uint256 ethReserve);
    event FeeAccrued(uint256 creatorFee, uint256 protocolFee, uint256 voterFee);

    // Legacy compat
    event TokensBought(address indexed buyer, uint256 indexed option, uint256 ethIn, uint256 tokensOut);
    event TokensSold(address indexed seller, uint256 indexed option, uint256 tokensIn, uint256 ethOut);

    // Arena lifecycle
    event OptionReaped(uint256 indexed loserIndex, uint256 ethRecovered);
    event ReapAnnounced(uint256 indexed loserIndex, uint256 executeAfter);
    event ArenaSettled(uint256 indexed winnerIndex, uint256 totalPayout);
    event ArenaFrozen();
    event ArenaCancelled();
    event PayoutClaimed(address indexed user, uint256 amount);
    event FeesWithdrawn(uint256 creatorAmount, uint256 protocolAmount);
    event ReporterRewardsDistributed(uint256 total, uint256 recipientCount);
    event Withdrawal(address indexed user, uint256 amount);

    // Reporter management
    event ReporterAdded(address indexed reporter);
    event ReporterRemoved(address indexed reporter);
    event ThresholdUpdated(uint256 newThreshold);
    event ReapAttested(uint256 indexed loserIndex, uint256 nonce, bytes32 evidenceHash);

    // ══════════════════════════════════════════════════════════════
    //  MODIFIERS
    // ══════════════════════════════════════════════════════════════

    modifier nonReentrant() {
        if (_locked == 2) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    modifier onlyAdmin() {
        if (msg.sender != resolver && msg.sender != creator) revert NotAdmin();
        _;
    }

    modifier onlyResolutionAuthority() {
        if (
            msg.sender != resolver &&
            msg.sender != creator &&
            !(msg.sender == votingContract && votingContract != address(0))
        ) revert NotResolutionAuthority();
        _;
    }

    /// @dev settle/reap/cancel restricted to resolver+creator only (not votingContract)
    modifier onlyResolverOrCreator() {
        if (msg.sender != resolver && msg.sender != creator) revert NotAdmin();
        _;
    }

    modifier onlyOpen() {
        if (phase != Phase.Open) revert MarketNotOpen();
        _;
    }

    modifier checkDeadline(uint256 _deadline) {
        if (block.timestamp > _deadline) revert DeadlineExpired();
        _;
    }

    // ══════════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ══════════════════════════════════════════════════════════════

    constructor(
        uint256 _marketId,
        address _creator,
        address _resolver,
        address _factory,
        string memory _question,
        string[] memory _options,
        uint256 _endTime,
        uint256 _protocolFeeBps,
        address _protocolFeeRecipient,
        string memory _categories,
        bool _agentOnly,
        uint256 _virtualLiquidity,
        uint256 _maxWalletBaseBps
    ) payable {
        if (_options.length < MIN_OPTIONS || _options.length > 32) revert InvalidOptionCount();
        if (_endTime <= block.timestamp) revert EndMustBeFuture();
        if (_protocolFeeBps > 500) revert FeeTooHigh();
        if (_virtualLiquidity == 0) revert InsufficientSeed();

        marketId = _marketId;
        creator = _creator;
        resolver = _resolver;
        factory = _factory;
        question = _question;
        endTime = _endTime;
        protocolFeeBps = _protocolFeeBps;
        protocolFeeRecipient = _protocolFeeRecipient;
        categories = _categories;
        agentOnly = _agentOnly;
        optionCount = _options.length;
        aliveCount = _options.length;
        phase = Phase.Open;
        virtualEthPerPool = _virtualLiquidity;
        maxWalletBaseBps = _maxWalletBaseBps;

        // Optional real ETH top-up split across pools (can be 0)
        uint256 realEthPerPool = msg.value / _options.length;
        uint256 seedPerPool = _virtualLiquidity + realEthPerPool;
        for (uint256 i = 0; i < _options.length; i++) {
            optionLabels.push(_options[i]);
            tokenReserve.push(INIT_TOKENS);
            ethReserve.push(seedPerPool);
            eliminated.push(false);
        }

        DOMAIN_SEPARATOR = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes("ArenaMarket")),
            keccak256(bytes("2")),
            block.chainid,
            address(this)
        ));
    }

    // ══════════════════════════════════════════════════════════════
    //  ROUTER-STYLE TRADING
    // ══════════════════════════════════════════════════════════════

    /// @notice Buy tokens with exact ETH in, slippage + deadline protected.
    function buyExactETHIn(
        uint256 _option,
        uint256 _minTokensOut,
        uint256 _deadline
    ) external payable nonReentrant onlyOpen checkDeadline(_deadline) {
        _requireValidBuy(_option);
        if (msg.value == 0) revert ZeroAmount();

        uint256 effectiveBps = _getEffectiveFeeBps();
        uint256 fee = (msg.value * effectiveBps) / 10_000;
        uint256 ethIn = msg.value - fee;
        uint256 tokensOut = _amm_buyOut(_option, ethIn);
        if (tokensOut == 0) revert ZeroAmount();
        if (tokensOut < _minTokensOut) revert SlippageExceeded();

        _doBuy(_option, ethIn, tokensOut, fee, true, effectiveBps);
    }

    /// @notice Buy exact number of tokens, refund unused ETH.
    function buyExactTokensOut(
        uint256 _option,
        uint256 _tokensOut,
        uint256 _maxEthIn,
        uint256 _deadline
    ) external payable nonReentrant onlyOpen checkDeadline(_deadline) {
        _requireValidBuy(_option);
        if (_tokensOut == 0) revert ZeroAmount();
        if (_tokensOut >= tokenReserve[_option]) revert SlippageExceeded();

        // ceil( R_e * tOut / (R_t - tOut) )
        uint256 denom = tokenReserve[_option] - _tokensOut;
        uint256 ethNeeded = (ethReserve[_option] * _tokensOut + denom - 1) / denom;
        // Gross-up for fee: ceil( ethNeeded * 10000 / (10000 - feeBps) )
        uint256 effectiveBps = _getEffectiveFeeBps();
        uint256 grossEth = (ethNeeded * 10_000 + (10_000 - effectiveBps) - 1) /
                           (10_000 - effectiveBps);
        if (grossEth > _maxEthIn) revert SlippageExceeded();
        if (msg.value < grossEth) revert InsufficientSeed();

        uint256 fee = grossEth - ethNeeded;
        _doBuy(_option, ethNeeded, _tokensOut, fee, false, effectiveBps);

        // Refund excess
        uint256 refund = msg.value - grossEth;
        if (refund > 0) _creditWithdrawal(msg.sender, refund);
    }

    /// @notice Sell exact tokens in, slippage + deadline protected.
    function sellExactTokensIn(
        uint256 _option,
        uint256 _tokensIn,
        uint256 _minEthOut,
        uint256 _deadline
    ) external nonReentrant checkDeadline(_deadline) {
        _requireValidSell(_option, _tokensIn);

        uint256 effectiveBps = _getEffectiveFeeBps();
        uint256 rawEthOut = _amm_sellOut(_option, _tokensIn);
        if (rawEthOut == 0) revert ZeroAmount();
        uint256 fee = (rawEthOut * effectiveBps) / 10_000;
        uint256 ethOut = rawEthOut - fee;
        if (ethOut < _minEthOut) revert SlippageExceeded();

        _doSell(_option, _tokensIn, rawEthOut, ethOut, fee, true, effectiveBps);
    }

    /// @notice Sell tokens for exact ETH out, slippage + deadline protected.
    function sellExactETHOut(
        uint256 _option,
        uint256 _ethOut,
        uint256 _maxTokensIn,
        uint256 _deadline
    ) external nonReentrant checkDeadline(_deadline) {
        if (_option >= optionCount) revert InvalidOption();
        if (eliminated[_option]) revert OptionEliminated();
        if (_ethOut == 0) revert ZeroAmount();

        // rawEthOut = ceil( ethOut * 10000 / (10000 - feeBps) )
        uint256 effectiveBps = _getEffectiveFeeBps();
        uint256 rawEthOut = (_ethOut * 10_000 + (10_000 - effectiveBps) - 1) /
                            (10_000 - effectiveBps);
        if (rawEthOut >= ethReserve[_option]) revert SlippageExceeded();

        // Virtual floor: cannot withdraw more than real (non-virtual) ETH
        // (Note: surge-fee recycling in _doSell may increase headroom slightly,
        //  but we enforce the conservative check here for early failure.)
        if (ethReserve[_option] - rawEthOut < virtualEthPerPool) revert BelowVirtualFloor();

        // Reverse AMM: tokensIn = R_t * rawEthOut / (R_e - rawEthOut)  (round up)
        uint256 tokensIn = (tokenReserve[_option] * rawEthOut + ethReserve[_option] - rawEthOut - 1) /
                           (ethReserve[_option] - rawEthOut);
        if (tokensIn > _maxTokensIn) revert SlippageExceeded();

        _requireValidSell(_option, tokensIn);

        uint256 fee = rawEthOut - _ethOut;
        _doSell(_option, tokensIn, rawEthOut, _ethOut, fee, false, effectiveBps);
    }

    /// @notice Legacy buy() — exact ETH in, no slippage.
    function buy(uint256 _option) external payable nonReentrant onlyOpen {
        _requireValidBuy(_option);
        if (msg.value == 0) revert ZeroAmount();

        uint256 effectiveBps = _getEffectiveFeeBps();
        uint256 fee = (msg.value * effectiveBps) / 10_000;
        uint256 ethIn = msg.value - fee;
        uint256 tokensOut = _amm_buyOut(_option, ethIn);
        if (tokensOut == 0) revert ZeroAmount();

        _doBuy(_option, ethIn, tokensOut, fee, true, effectiveBps);
    }

    /// @notice Legacy sell() — exact tokens in, no slippage.
    function sell(uint256 _option, uint256 _tokenAmount) external nonReentrant {
        _requireValidSell(_option, _tokenAmount);

        uint256 effectiveBps = _getEffectiveFeeBps();
        uint256 rawEthOut = _amm_sellOut(_option, _tokenAmount);
        if (rawEthOut == 0) revert ZeroAmount();
        uint256 fee = (rawEthOut * effectiveBps) / 10_000;
        uint256 ethOut = rawEthOut - fee;

        _doSell(_option, _tokenAmount, rawEthOut, ethOut, fee, true, effectiveBps);
    }

    // ══════════════════════════════════════════════════════════════
    //  TRADE INTERNALS
    // ══════════════════════════════════════════════════════════════

    function _requireValidBuy(uint256 _option) internal view {
        if (_option >= optionCount) revert InvalidOption();
        if (eliminated[_option]) revert OptionEliminated();
        if (agentOnly && !IClawshiFactory(factory).isAgent(msg.sender)) revert AgentsOnly();
    }

    function _requireValidSell(uint256 _option, uint256 _amount) internal view {
        if (_option >= optionCount) revert InvalidOption();
        if (eliminated[_option]) revert OptionEliminated();
        // Sell allowed in Open or Cancelled; blocked in Frozen/Settled
        if (phase == Phase.Frozen || phase == Phase.Settled) revert TradingClosed();
        if (_amount == 0) revert ZeroAmount();
        if (balances[msg.sender][_option] < _amount) revert InsufficientBalance();
        if (agentOnly && phase != Phase.Cancelled) {
            if (!IClawshiFactory(factory).isAgent(msg.sender)) revert AgentsOnly();
        }
    }

    function _amm_buyOut(uint256 _opt, uint256 _ethIn) internal view returns (uint256) {
        return (tokenReserve[_opt] * _ethIn) / (ethReserve[_opt] + _ethIn);
    }

    function _amm_sellOut(uint256 _opt, uint256 _tokensIn) internal view returns (uint256) {
        uint256 rawOut = (ethReserve[_opt] * _tokensIn) / (tokenReserve[_opt] + _tokensIn);
        // Cap: cannot withdraw virtual ETH — only real ETH is withdrawable
        uint256 floor = virtualEthPerPool;
        if (ethReserve[_opt] - rawOut < floor) {
            // Clamp to keep ethReserve >= virtualEthPerPool
            rawOut = ethReserve[_opt] > floor ? ethReserve[_opt] - floor : 0;
        }
        return rawOut;
    }

    function _doBuy(
        uint256 _option, uint256 _ethIn, uint256 _tokensOut, uint256 _fee, bool _exactIn, uint256 _effectiveBps
    ) internal {
        _splitFee(_fee, _effectiveBps, _option);

        tokenReserve[_option] -= _tokensOut;
        ethReserve[_option]   += _ethIn;
        balances[msg.sender][_option] += _tokensOut;

        // Max wallet check (0 = disabled)
        if (maxWalletBaseBps > 0) {
            uint256 cap = _maxWalletTokens(_option);
            if (balances[msg.sender][_option] > cap) revert MaxWalletExceeded();
        }

        _addParticipant(msg.sender);

        emit TokensBought(msg.sender, _option, _ethIn, _tokensOut);
        emit Swap(msg.sender, _option, _exactIn, true, _ethIn + _fee, _tokensOut, _fee);
        emit Sync(_option, tokenReserve[_option], ethReserve[_option]);
    }

    function _doSell(
        uint256 _option, uint256 _tokensIn, uint256 _rawEthOut, uint256 _ethOut, uint256 _fee, bool _exactIn, uint256 _effectiveBps
    ) internal {
        _splitFee(_fee, _effectiveBps, _option);

        // ── Virtual floor invariant (belt & suspenders) ──────────
        // After surge-fee recycling, ensure the withdrawal keeps
        // ethReserve above the virtual seed.  This is the canonical
        // enforcement point — all sell paths funnel through here.
        if (ethReserve[_option] < _rawEthOut ||
            ethReserve[_option] - _rawEthOut < virtualEthPerPool)
            revert BelowVirtualFloor();

        tokenReserve[_option] += _tokensIn;
        ethReserve[_option]   -= _rawEthOut;
        balances[msg.sender][_option] -= _tokensIn;

        _creditWithdrawal(msg.sender, _ethOut);

        emit TokensSold(msg.sender, _option, _tokensIn, _ethOut);
        emit Swap(msg.sender, _option, _exactIn, false, _tokensIn, _ethOut, _fee);
        emit Sync(_option, tokenReserve[_option], ethReserve[_option]);
    }

    // ══════════════════════════════════════════════════════════════
    //  PULL-BASED WITHDRAWAL
    // ══════════════════════════════════════════════════════════════

    /// @notice Withdraw all pending ETH (from sells, claims, fees, refunds)
    function withdraw() external nonReentrant {
        uint256 amount = pendingWithdrawal[msg.sender];
        if (amount == 0) revert NothingToWithdraw();

        pendingWithdrawal[msg.sender] = 0;
        totalPendingWithdrawals -= amount;

        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit Withdrawal(msg.sender, amount);
    }

    function _creditWithdrawal(address _to, uint256 _amount) internal {
        if (_amount == 0) return;
        pendingWithdrawal[_to] += _amount;
        totalPendingWithdrawals += _amount;
    }

    // ══════════════════════════════════════════════════════════════
    //  REAPING (MID-EVENT ELIMINATION) — MEV-PROTECTED
    // ══════════════════════════════════════════════════════════════

    /// @notice Announce intent to eliminate an option.
    function announceReap(uint256 _loserIndex) external onlyResolverOrCreator {
        if (phase == Phase.Settled || phase == Phase.Cancelled) revert MarketAlreadyClosed();
        if (_loserIndex >= optionCount) revert InvalidOption();
        if (eliminated[_loserIndex]) revert AlreadyEliminated();
        if (aliveCount <= 1) revert CannotReapLast();
        if (pendingReap.active) revert ReapAlreadyPending();

        // Snapshot survivor weights at announce time (front-run protection)
        delete reapWeightSnapshot;
        for (uint256 i = 0; i < optionCount; i++) {
            reapWeightSnapshot.push(eliminated[i] ? 0 : ethReserve[i]);
        }

        pendingReap = PendingReap(_loserIndex, block.timestamp, true);
        emit ReapAnnounced(_loserIndex, block.timestamp + REAP_DELAY);
    }

    /// @notice Execute a previously announced reap after delay.
    function executeReap() external nonReentrant onlyResolverOrCreator {
        if (!pendingReap.active) revert NoReapPending();
        if (block.timestamp < pendingReap.announceTime + REAP_DELAY) revert ReapDelayNotPassed();

        uint256 loserIdx = pendingReap.loserIndex;
        pendingReap.active = false;

        if (phase == Phase.Settled || phase == Phase.Cancelled) revert MarketAlreadyClosed();
        if (eliminated[loserIdx]) revert AlreadyEliminated();
        if (aliveCount <= 1) revert CannotReapLast();

        eliminated[loserIdx] = true;
        aliveCount--;

        uint256 loserEth = ethReserve[loserIdx];
        ethReserve[loserIdx] = 0;
        tokenReserve[loserIdx] = 0;
        emit Sync(loserIdx, 0, 0);

        if (loserEth == 0) {
            emit OptionReaped(loserIdx, 0);
            return;
        }

        // ── Final-3 rule: when aliveCount <= PRIZE_POT_THRESHOLD, ──
        // ── reaped ETH goes to settlementPool (prize pot) instead ──
        // ── of surviving pools — incentivizes holding to the end. ──
        if (aliveCount <= PRIZE_POT_THRESHOLD) {
            // Only real ETH goes to prize pot (exclude virtual)
            uint256 realEth = loserEth > virtualEthPerPool ? loserEth - virtualEthPerPool : 0;
            settlementPool += realEth;
            emit OptionReaped(loserIdx, realEth);
            return;
        }

        // ── Normal reap: distribute only REAL loser ETH to alive pools ──
        // (virtual ETH was never deposited — distributing it inflates obligations)
        uint256 realLoserEth = loserEth > virtualEthPerPool ? loserEth - virtualEthPerPool : 0;
        if (realLoserEth == 0) {
            emit OptionReaped(loserIdx, 0);
            return;
        }

        uint256 totalSnapWeight = 0;
        for (uint256 i = 0; i < optionCount; i++) {
            if (i != loserIdx && !eliminated[i]) totalSnapWeight += reapWeightSnapshot[i];
        }

        uint256 distributed = 0;
        if (totalSnapWeight > 0) {
            for (uint256 i = 0; i < optionCount; i++) {
                if (i != loserIdx && !eliminated[i]) {
                    uint256 share = (realLoserEth * reapWeightSnapshot[i]) / totalSnapWeight;
                    ethReserve[i] += share;
                    distributed += share;
                    emit Sync(i, tokenReserve[i], ethReserve[i]);
                }
            }
        }

        // Rounding dust → first alive pool
        if (distributed < realLoserEth) {
            uint256 first = _findFirstAlive();
            ethReserve[first] += (realLoserEth - distributed);
            emit Sync(first, tokenReserve[first], ethReserve[first]);
        }

        emit OptionReaped(loserIdx, realLoserEth);
    }

    /// @notice Cancel a pending reap announcement.
    function cancelReap() external onlyResolverOrCreator {
        if (!pendingReap.active) revert NoReapPending();
        pendingReap.active = false;
    }

    // ══════════════════════════════════════════════════════════════
    //  THRESHOLD-SIGNER REAP (EIP-712)
    // ══════════════════════════════════════════════════════════════

    function announceReapWithSigs(
        ReapAuthorization calldata auth,
        bytes[] calldata sigs
    ) external nonReentrant {
        if (auth.marketId != marketId) revert WrongMarket();
        if (auth.nonce != reapNonce) revert InvalidNonce();
        if (auth.loserIndex >= optionCount) revert InvalidOption();
        if (eliminated[auth.loserIndex]) revert AlreadyEliminated();
        if (aliveCount <= 1) revert CannotReapLast();
        if (phase == Phase.Settled || phase == Phase.Cancelled) revert MarketAlreadyClosed();
        if (pendingReap.active) revert ReapAlreadyPending();

        if (auth.validAfter > 0 && block.timestamp < auth.validAfter) revert TooEarly();
        if (auth.validBefore > 0 && block.timestamp > auth.validBefore) revert AuthExpired();
        if (auth.expectedAliveCount > 0 && aliveCount != auth.expectedAliveCount) revert AliveCountMismatch();

        if (threshold == 0) revert ThresholdNotSet();
        if (sigs.length < threshold) revert NotEnoughSignatures();
        if (sigs.length > MAX_SIGS) revert TooManySignatures();

        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01",
            DOMAIN_SEPARATOR,
            keccak256(abi.encode(
                REAP_AUTHORIZATION_TYPEHASH,
                auth.marketId, auth.loserIndex, auth.expectedAliveCount,
                auth.nonce, auth.validAfter, auth.validBefore, auth.evidenceHash
            ))
        ));

        address lastSigner = address(0);
        uint256 validCount = 0;
        for (uint256 i = 0; i < sigs.length && validCount < threshold; i++) {
            address signer = _recoverSigner(digest, sigs[i]);
            if (signer <= lastSigner) revert SigsNotSorted();
            if (!reporters[signer]) revert NotReporter();
            lastSigner = signer;
            validCount++;
        }
        if (validCount < threshold) revert NotEnoughSignatures();

        reapNonce++;

        // Snapshot survivor weights at announce time (front-run protection)
        delete reapWeightSnapshot;
        for (uint256 i = 0; i < optionCount; i++) {
            reapWeightSnapshot.push(eliminated[i] ? 0 : ethReserve[i]);
        }

        pendingReap = PendingReap(auth.loserIndex, block.timestamp, true);

        emit ReapAttested(auth.loserIndex, auth.nonce, auth.evidenceHash);
        emit ReapAnnounced(auth.loserIndex, block.timestamp + REAP_DELAY);
    }

    /// @dev Recover signer with low-s enforcement (EIP-2 malleable sig protection)
    function _recoverSigner(bytes32 _digest, bytes memory _sig) internal pure returns (address) {
        if (_sig.length != 65) revert InvalidSignature();
        bytes32 r; bytes32 s; uint8 v;
        assembly {
            r := mload(add(_sig, 32))
            s := mload(add(_sig, 64))
            v := byte(0, mload(add(_sig, 96)))
        }
        if (v < 27) v += 27;
        if (v != 27 && v != 28) revert InvalidSignature();
        if (uint256(s) > _HALF_ORDER) revert InvalidSignature(); // low-s
        address signer = ecrecover(_digest, v, r, s);
        if (signer == address(0)) revert InvalidSignature();
        return signer;
    }

    // ══════════════════════════════════════════════════════════════
    //  REPORTER MANAGEMENT (onlyAdmin — NOT votingContract)
    // ══════════════════════════════════════════════════════════════

    function addReporter(address _reporter) external onlyAdmin {
        if (_reporter == address(0)) revert ZeroAddress();
        if (reporters[_reporter]) revert AlreadyReporter();
        reporters[_reporter] = true;
        reporterCount++;
        emit ReporterAdded(_reporter);
    }

    function removeReporter(address _reporter) external onlyAdmin {
        if (!reporters[_reporter]) revert NotReporter();
        reporters[_reporter] = false;
        reporterCount--;
        if (threshold > reporterCount) {
            threshold = reporterCount;
            emit ThresholdUpdated(threshold);
        }
        emit ReporterRemoved(_reporter);
    }

    function setThreshold(uint256 _threshold) external onlyAdmin {
        if (_threshold == 0 || _threshold > reporterCount) revert InvalidThreshold();
        threshold = _threshold;
        emit ThresholdUpdated(_threshold);
    }

    // ══════════════════════════════════════════════════════════════
    //  SETTLEMENT
    // ══════════════════════════════════════════════════════════════

    /// @notice Freeze the arena — no more trading.
    function freeze() external {
        if (phase != Phase.Open) revert AlreadyFrozenOrClosed();
        if (block.timestamp < endTime && msg.sender != resolver && msg.sender != creator)
            revert NotYetEnded();
        phase = Phase.Frozen;
        emit ArenaFrozen();
    }

    /// @notice Declare winner. All surviving pool ETH → settlement pot.
    function settle(uint256 _winnerIndex) external nonReentrant onlyResolverOrCreator {
        if (phase == Phase.Settled || phase == Phase.Cancelled) revert MarketAlreadyClosed();
        if (_winnerIndex >= optionCount) revert InvalidOption();
        if (eliminated[_winnerIndex]) revert WinnerEliminated();

        // Auto-freeze
        if (phase == Phase.Open) {
            phase = Phase.Frozen;
            emit ArenaFrozen();
        }
        phase = Phase.Settled;
        winnerIndex = _winnerIndex;

        // Collect only REAL ETH from reserves into settlement pot
        // (virtual ETH doesn't exist as real balance)
        uint256 pool = settlementPool; // include any prize-pot ETH from final-3 reaps
        for (uint256 i = 0; i < optionCount; i++) {
            if (ethReserve[i] > virtualEthPerPool) {
                pool += ethReserve[i] - virtualEthPerPool;
            }
            if (ethReserve[i] > 0) {
                ethReserve[i] = 0;
                emit Sync(i, tokenReserve[i], 0);
            }
        }
        settlementPool = pool;
        settleTime = block.timestamp;

        winnerCirculatingAtSettle = INIT_TOKENS - tokenReserve[_winnerIndex];

        // Invariant: winner circulating must equal sum of all user balances
        uint256 balSum = 0;
        for (uint256 j = 0; j < participants.length; j++) {
            balSum += balances[participants[j]][_winnerIndex];
        }
        if (balSum != winnerCirculatingAtSettle) revert WinnerSupplyMismatch();

        emit ArenaSettled(_winnerIndex, pool);
    }

    /// @notice Claim payout (winner-token holders only). Pull-based.
    function claimPayout() external nonReentrant {
        if (phase != Phase.Settled) revert MarketNotSettled();
        if (claimedSettlement[msg.sender]) revert AlreadyClaimed();
        claimedSettlement[msg.sender] = true;

        uint256 userBal = balances[msg.sender][winnerIndex];
        if (userBal == 0 || winnerCirculatingAtSettle == 0) {
            emit PayoutClaimed(msg.sender, 0);
            return;
        }

        uint256 payout = (settlementPool * userBal) / winnerCirculatingAtSettle;
        // Safety cap: prevent dust/rounding from reverting later claims
        if (payout > settlementPool) payout = settlementPool;
        balances[msg.sender][winnerIndex] = 0;
        settlementPool -= payout;
        winnerCirculatingAtSettle -= userBal;

        if (payout > 0) _creditWithdrawal(msg.sender, payout);
        emit PayoutClaimed(msg.sender, payout);
    }

    // ══════════════════════════════════════════════════════════════
    //  CANCELLATION
    // ══════════════════════════════════════════════════════════════

    /// @notice Cancel the arena. Buys disabled, sells allowed for unwinding.
    function cancel() external onlyResolverOrCreator {
        if (phase == Phase.Settled || phase == Phase.Cancelled) revert MarketAlreadyClosed();
        phase = Phase.Cancelled;
        settleTime = block.timestamp;
        emit ArenaCancelled();
    }

    // ══════════════════════════════════════════════════════════════
    //  FEE MANAGEMENT
    // ══════════════════════════════════════════════════════════════

    /// @dev Compute effective fee rate based on time remaining until endTime
    function _getEffectiveFeeBps() internal view returns (uint256) {
        if (block.timestamp >= endTime) return protocolFeeBps;
        uint256 remaining = endTime - block.timestamp;

        uint256 tierBps;
        if      (remaining <= 3 minutes)  tierBps = 2500;  // 25%
        else if (remaining <= 10 minutes) tierBps = 1500;  // 15%
        else if (remaining <= 30 minutes) tierBps = 1250;  // 12.5%
        else if (remaining <= 1 hours)    tierBps = 1000;  // 10%
        else if (remaining <= 3 hours)    tierBps = 700;   // 7%
        else if (remaining <= 6 hours)    tierBps = 500;   // 5%
        else return protocolFeeBps;

        return tierBps > protocolFeeBps ? tierBps : protocolFeeBps;
    }

    /// @dev Split fee considering surge tiers. Above SURGE_BASE_BPS (1%), excess
    ///      is routed: 70% liquidity / 10% creator / 10% protocol / 10% reporters.
    function _splitFee(uint256 _fee, uint256 _effectiveBps, uint256 _option) internal {
        if (_fee == 0) return;

        // If effective rate is at or below 1%, entire fee uses base split
        if (_effectiveBps <= SURGE_BASE_BPS) {
            _splitFeeBase(_fee);
            return;
        }

        // Separate base (first 1% worth) from surge (above 1%)
        uint256 baseFee  = (_fee * SURGE_BASE_BPS) / _effectiveBps;
        uint256 surgeFee = _fee - baseFee;

        _splitFeeBase(baseFee);

        // Surge: 70% → pool liquidity, 10% creator, 10% protocol, 10% reporters
        uint256 toLiq = (surgeFee * 70) / 100;
        uint256 toCre = (surgeFee * 10) / 100;
        uint256 toPro = (surgeFee * 10) / 100;
        uint256 toRep = surgeFee - toLiq - toCre - toPro;

        ethReserve[_option] += toLiq;
        accCreatorFees      += toCre;
        accProtocolFees     += toPro;
        accReporterRewards  += toRep;

        emit Sync(_option, tokenReserve[_option], ethReserve[_option]);
    }

    /// @dev Base fee split: 60% creator / 40% protocol (with voter reward carved from protocol)
    function _splitFeeBase(uint256 _fee) internal {
        if (_fee == 0) return;
        uint256 creatorShare  = (_fee * 60) / 100;
        uint256 protocolShare = _fee - creatorShare;
        uint256 voterShare    = (protocolShare * voterRewardBps) / 10_000;
        uint256 protocolNet   = protocolShare - voterShare;

        accCreatorFees  += creatorShare;
        accVoterRewards += voterShare;
        accProtocolFees += protocolNet;

        emit FeeAccrued(creatorShare, protocolNet, voterShare);
    }

    /// @notice Withdraw accumulated trading fees (pull-based).
    function withdrawFees() external nonReentrant {
        uint256 cAmt = accCreatorFees;
        uint256 pAmt = accProtocolFees;
        accCreatorFees = 0;
        accProtocolFees = 0;

        if (cAmt > 0) _creditWithdrawal(creator, cAmt);
        if (pAmt > 0) _creditWithdrawal(protocolFeeRecipient, pAmt);

        emit FeesWithdrawn(cAmt, pAmt);
    }

    /// @notice Send accumulated resolver rewards to the UMA resolution oracle
    function claimVoterRewards() external nonReentrant {
        if (votingContract == address(0)) revert NoVotingContract();
        uint256 amt = accVoterRewards;
        if (amt == 0) revert NoRewardsToClaim();
        accVoterRewards = 0;
        try IVotingOracle(votingContract).depositVoterReward{value: amt}(marketId) {
            // success
        } catch {
            // Oracle reverted — credit to protocol fee recipient instead
            _creditWithdrawal(protocolFeeRecipient, amt);
        }
    }

    /// @notice Close betting (freeze) and flush resolver rewards.
    function closeBetting() external nonReentrant {
        if (phase == Phase.Settled || phase == Phase.Cancelled) revert MarketAlreadyClosed();
        if (block.timestamp < endTime && msg.sender != resolver && msg.sender != creator)
            revert NotYetEnded();

        if (phase == Phase.Open) {
            phase = Phase.Frozen;
            emit ArenaFrozen();
        }

        if (votingContract != address(0) && accVoterRewards > 0) {
            uint256 amt = accVoterRewards;
            accVoterRewards = 0;
            try IVotingOracle(votingContract).depositVoterReward{value: amt}(marketId) {
                // success
            } catch {
                _creditWithdrawal(protocolFeeRecipient, amt);
            }
        }
    }

    /// @notice Configure UMA resolution oracle (admin only)
    function setVotingConfig(address _votingContract, uint256 _voterRewardBps) external onlyAdmin {
        if (_voterRewardBps > 10_000) revert VoterRewardTooHigh();
        votingContract = _votingContract;
        voterRewardBps = _voterRewardBps;
    }

    /// @notice Distribute accumulated reporter rewards equally to specified addresses
    function flushReporterRewards(address[] calldata _to) external nonReentrant onlyAdmin {
        uint256 total = accReporterRewards;
        if (total == 0) revert NoRewardsToClaim();
        if (_to.length == 0) revert ZeroAmount();

        uint256 share = total / _to.length;
        if (share == 0) revert ZeroAmount();

        uint256 distributed = share * _to.length;
        accReporterRewards = total - distributed;

        for (uint256 i = 0; i < _to.length; i++) {
            _creditWithdrawal(_to[i], share);
        }
        emit ReporterRewardsDistributed(distributed, _to.length);
    }

    /// @notice Get the current effective fee rate (accounts for surge tiers near endTime)
    function getEffectiveFeeBps() external view returns (uint256) {
        return _getEffectiveFeeBps();
    }

    /// @notice Current max tokens any single wallet can hold for this option.
    ///         Returns type(uint256).max if max wallet is disabled.
    function getMaxWalletTokens(uint256 _option) external view returns (uint256) {
        if (maxWalletBaseBps == 0) return type(uint256).max;
        return _maxWalletTokens(_option);
    }

    /// @notice Current max wallet bps (base + reap boost + LP boost, capped)
    function getMaxWalletBps() external view returns (uint256) {
        if (maxWalletBaseBps == 0) return 10_000;
        uint256 reapsDone = optionCount - aliveCount;
        uint256 bps = maxWalletBaseBps + (reapsDone * MAX_WALLET_REAP_BOOST_BPS);
        if (bps > MAX_WALLET_HARD_CAP_BPS) bps = MAX_WALLET_HARD_CAP_BPS;
        return bps; // note: LP boost is per-option, this returns base+reap only
    }

    // ══════════════════════════════════════════════════════════════
    //  VIEW FUNCTIONS — QUOTES & RESERVES
    // ══════════════════════════════════════════════════════════════

    /// @notice Get reserves for an option (Uniswap v2 style)
    function getReserves(uint256 _option) external view returns (uint256 tokenRes, uint256 ethRes) {
        if (_option >= optionCount) revert InvalidOption();
        return (tokenReserve[_option], ethReserve[_option]);
    }

    /// @notice Spot price in wei per token
    function getSpotPriceWeiPerToken(uint256 _option) external view returns (uint256) {
        if (_option >= optionCount || eliminated[_option] || tokenReserve[_option] == 0) return 0;
        return (ethReserve[_option] * 1e18) / tokenReserve[_option];
    }

    /// @notice Legacy getPrice alias
    function getPrice(uint256 _option) external view returns (uint256) {
        if (_option >= optionCount || eliminated[_option] || tokenReserve[_option] == 0) return 0;
        return (ethReserve[_option] * 1e18) / tokenReserve[_option];
    }

    /// @notice Quote: buy exact ETH in → tokens out (after fees)
    function quoteBuyExactIn(uint256 _option, uint256 _ethAmount) external view returns (uint256) {
        if (_option >= optionCount || eliminated[_option]) return 0;
        uint256 feeBps = _getEffectiveFeeBps();
        uint256 ethIn = _ethAmount - (_ethAmount * feeBps) / 10_000;
        return (tokenReserve[_option] * ethIn) / (ethReserve[_option] + ethIn);
    }

    /// @notice Quote: buy exact tokens out → ETH required (including fees)
    function quoteBuyExactOut(uint256 _option, uint256 _tokensOut) external view returns (uint256) {
        if (_option >= optionCount || eliminated[_option]) return 0;
        if (_tokensOut >= tokenReserve[_option]) return type(uint256).max;
        uint256 denom = tokenReserve[_option] - _tokensOut;
        uint256 ethNeeded = (ethReserve[_option] * _tokensOut + denom - 1) / denom;
        uint256 feeBps = _getEffectiveFeeBps();
        return (ethNeeded * 10_000 + (10_000 - feeBps) - 1) / (10_000 - feeBps);
    }

    /// @notice Quote: sell exact tokens in → ETH out (after fees)
    function quoteSellExactIn(uint256 _option, uint256 _tokensIn) external view returns (uint256) {
        if (_option >= optionCount || eliminated[_option]) return 0;
        uint256 raw = (ethReserve[_option] * _tokensIn) / (tokenReserve[_option] + _tokensIn);
        // Clamp: cannot withdraw below virtual liquidity floor
        uint256 floor = virtualEthPerPool;
        if (ethReserve[_option] - raw < floor) {
            raw = ethReserve[_option] > floor ? ethReserve[_option] - floor : 0;
        }
        if (raw == 0) return 0;
        return raw - (raw * _getEffectiveFeeBps()) / 10_000;
    }

    /// @notice Quote: sell for exact ETH out → tokens required
    function quoteSellExactOut(uint256 _option, uint256 _ethOut) external view returns (uint256) {
        if (_option >= optionCount || eliminated[_option]) return 0;
        uint256 feeBps = _getEffectiveFeeBps();
        uint256 raw = (_ethOut * 10_000 + (10_000 - feeBps) - 1) / (10_000 - feeBps);
        if (raw >= ethReserve[_option]) return type(uint256).max;
        // Cannot withdraw below virtual liquidity floor
        uint256 available = ethReserve[_option] > virtualEthPerPool
            ? ethReserve[_option] - virtualEthPerPool : 0;
        if (raw > available) return type(uint256).max;
        return (tokenReserve[_option] * raw + ethReserve[_option] - raw - 1) / (ethReserve[_option] - raw);
    }

    /// @notice Legacy quoteBuy (same as quoteBuyExactIn)
    function quoteBuy(uint256 _option, uint256 _ethAmount) external view returns (uint256) {
        if (_option >= optionCount || eliminated[_option]) return 0;
        uint256 ethIn = _ethAmount - (_ethAmount * _getEffectiveFeeBps()) / 10_000;
        return (tokenReserve[_option] * ethIn) / (ethReserve[_option] + ethIn);
    }

    /// @notice Legacy quoteSell (same as quoteSellExactIn)
    function quoteSell(uint256 _option, uint256 _tokenAmount) external view returns (uint256) {
        if (_option >= optionCount || eliminated[_option]) return 0;
        uint256 raw = (ethReserve[_option] * _tokenAmount) / (tokenReserve[_option] + _tokenAmount);
        // Clamp: cannot withdraw below virtual liquidity floor
        uint256 floor = virtualEthPerPool;
        if (ethReserve[_option] - raw < floor) {
            raw = ethReserve[_option] > floor ? ethReserve[_option] - floor : 0;
        }
        if (raw == 0) return 0;
        return raw - (raw * _getEffectiveFeeBps()) / 10_000;
    }

    /// @notice Implied odds (basis points, sum ≈ 10000 for alive options)
    function getOdds() external view returns (uint256[] memory) {
        uint256[] memory odds = new uint256[](optionCount);
        uint256 totalEth = 0;
        for (uint256 i = 0; i < optionCount; i++) {
            if (!eliminated[i]) totalEth += ethReserve[i];
        }
        if (totalEth == 0) return odds;
        for (uint256 i = 0; i < optionCount; i++) {
            if (!eliminated[i]) odds[i] = (ethReserve[i] * 10_000) / totalEth;
        }
        return odds;
    }

    /// @notice User's token balances across all options
    function getPosition(address _user) external view returns (uint256[] memory) {
        uint256[] memory pos = new uint256[](optionCount);
        for (uint256 i = 0; i < optionCount; i++) pos[i] = balances[_user][i];
        return pos;
    }

    /// @notice Pool state for one option
    function getPoolState(uint256 _option) external view returns (
        uint256 _tokenReserve, uint256 _ethReserve, bool _eliminated, string memory _label
    ) {
        if (_option >= optionCount) revert InvalidOption();
        return (tokenReserve[_option], ethReserve[_option], eliminated[_option], optionLabels[_option]);
    }

    /// @notice Full market summary (backward-compatible return shape)
    function getMarketInfo() external view returns (
        string memory _question, uint256 _endTime, uint256 _optionCount, uint256 _aliveCount,
        bool _settled, bool _cancelled, bool _frozen, uint256 _winnerIndex,
        address _creator, bool _agentOnly, uint256 _totalEth
    ) {
        return (
            question, endTime, optionCount, aliveCount,
            phase == Phase.Settled, phase == Phase.Cancelled,
            phase == Phase.Frozen || phase == Phase.Settled,
            winnerIndex, creator, agentOnly, _sumRealPoolEth() + settlementPool
        );
    }

    /// @notice Get all options data in one call
    function getOptions() external view returns (
        string[] memory labels, uint256[] memory ethReserves,
        uint256[] memory tokenReserves, bool[] memory elim
    ) {
        return (optionLabels, ethReserve, tokenReserve, eliminated);
    }

    function getParticipantCount() external view returns (uint256) { return participants.length; }

    function circulatingSupply(uint256 _option) external view returns (uint256) {
        if (_option >= optionCount || tokenReserve[_option] > INIT_TOKENS) return 0;
        return INIT_TOKENS - tokenReserve[_option];
    }

    function totalValueLocked() external view returns (uint256) {
        return _sumRealPoolEth() + settlementPool;
    }

    /// @notice Solvency check — returns true if contract balance covers all obligations
    /// @dev Partitioned buckets: poolEth (mutual exclusive with settlementPool) + fees + pending
    function isSolvent() external view returns (bool) {
        return address(this).balance >= _totalObligations();
    }

    /// @notice Total ETH the contract owes across all buckets
    function totalObligations() external view returns (uint256) {
        return _totalObligations();
    }

    /// @notice Detailed obligation breakdown for invariant testing
    function getObligationBreakdown() external view returns (
        uint256 poolEth, uint256 settlement, uint256 creatorFees,
        uint256 protocolFees, uint256 voterRewards, uint256 reporterRewards, uint256 pending
    ) {
        return (
            _sumRealPoolEth(), settlementPool,
            accCreatorFees, accProtocolFees, accVoterRewards,
            accReporterRewards, totalPendingWithdrawals
        );
    }

    // ══════════════════════════════════════════════════════════════
    //  INTERNALS
    // ══════════════════════════════════════════════════════════════

    /// @dev sum of REAL ETH in pools (total ethReserve minus virtual portion per alive pool)
    function _sumRealPoolEth() internal view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < optionCount; i++) {
            if (ethReserve[i] > virtualEthPerPool) {
                total += ethReserve[i] - virtualEthPerPool;
            }
        }
        return total;
    }

    /// @dev Total obligations = real pool ETH + settlement + fees + pending withdrawals
    ///      Virtual ETH is excluded since it was never deposited.
    function _totalObligations() internal view returns (uint256) {
        return _sumRealPoolEth() + settlementPool +
               accCreatorFees + accProtocolFees + accVoterRewards +
               accReporterRewards + totalPendingWithdrawals;
    }

    /// @dev Max tokens per wallet per option, scales with LP depth + reaps
    function _maxWalletTokens(uint256 _option) internal view returns (uint256) {
        uint256 reapsDone = optionCount - aliveCount;
        uint256 bps = maxWalletBaseBps + (reapsDone * MAX_WALLET_REAP_BOOST_BPS);

        // LP depth boost: +0.5% per 1 ETH of real liquidity in this pool
        uint256 realEth = ethReserve[_option] > virtualEthPerPool
            ? ethReserve[_option] - virtualEthPerPool : 0;
        uint256 lpBoost = (realEth * MAX_WALLET_LP_SCALE_BPS) / 1e18;
        if (lpBoost > MAX_WALLET_LP_CAP_BPS) lpBoost = MAX_WALLET_LP_CAP_BPS;
        bps += lpBoost;

        if (bps > MAX_WALLET_HARD_CAP_BPS) bps = MAX_WALLET_HARD_CAP_BPS;
        return (INIT_TOKENS * bps) / 10_000;
    }

    function _findFirstAlive() internal view returns (uint256) {
        for (uint256 i = 0; i < optionCount; i++) {
            if (!eliminated[i]) return i;
        }
        return 0;
    }

    function _addParticipant(address _user) internal {
        if (!_isPart[_user]) {
            _isPart[_user] = true;
            participants.push(_user);
        }
    }

    // ══════════════════════════════════════════════════════════════
    //  EMERGENCY
    // ══════════════════════════════════════════════════════════════

    /// @notice Emergency sweep for creator — only excess over obligations, after 30-day delay
    function emergencySweep() external nonReentrant {
        if (msg.sender != creator) revert NotCreator();
        if (phase != Phase.Settled && phase != Phase.Cancelled) revert NotClosedYet();
        if (block.timestamp < settleTime + SWEEP_DELAY) revert SweepTooEarly();

        uint256 obligations = _totalObligations();
        uint256 bal = address(this).balance;
        if (bal <= obligations) revert NothingToSweep();
        uint256 excess = bal - obligations;

        (bool ok,) = creator.call{value: excess}("");
        if (!ok) revert TransferFailed();
    }

    /// @dev Reject raw ETH sends — prevents unaccounted balance drift.
    receive() external payable {
        revert DirectETHNotAllowed();
    }
}
